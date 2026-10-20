package crossfire_editor

import "core:fmt"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
What the project browser does with scenes: its context menu and keys (`Scene_Action`), renaming a
scene in place, and the Project Settings dialog. The model operations are in project_scenes.odin.

Keys: while the browser has focus (`State.browserFocused`), the node shortcuts act on the selected
scene instead: Delete, Ctrl+D (duplicate), Ctrl+C / Ctrl+X / Ctrl+V, F2 (rename). See
`Browser_RouteAction`.
*/

// The Project Settings dialog's tabs
ProjectSettingsTab :: enum {
	General,
	Input,
	Globals,
	Export,
	Grid,
}

// The Project Settings dialog edits a copy of these; Apply sets them as one undoable step
ProjectSettingsDialog :: struct {
	open: bool,
	// Shown as the Settings dialog's Project tab instead of its own dialog: the Settings dialog's
	// Apply, Save and Cancel act on it too
	embedded: bool,
	tab: ProjectSettingsTab,
	// The Export tab's target
	exportTarget: ExportTarget,
	exports: ExportSettings,
	// Owned
	name: string,
	gameSize: [2]f32,
	scaleMode: e.ScaleMode,
	renderer: e.RenderBackend,
	background: skald.Color,
	// Owned
	startScene: string,
	// Owned: the language the game starts in ("" for the player's)
	locale: string,
	// Owned: the window icon's image ("" for the engine's)
	icon: string,
	physics: e.PhysicsSettings,
	window: e.WindowSettings,
	// The sound output's format
	audioOutput: e.AudioOutputSettings,
	// Grid tab: the viewport grid
	grid: e.GridSettings,
	// Globals tab: a copy of the project's globals (owned), and the one shown
	globals: [dynamic]GlobalDef,
	selectedGlobal: int,
	// Input tab: a copy of the project's actions (owned), the one shown, a new action's name
	// (owned), a rename being typed (owned), and capturing a binding (the modifiers held when it
	// started, so a modifier pressed on its own is noticed); the device new gamepad bindings get
	actions: [dynamic]ActionDef,
	selectedAction: int,
	newActionName: string,
	renameText: string,
	capturing: bool,
	captureModifiers: skald.Modifiers,
	bindingDevice: int,
}

/*
The scene a browser shortcut acts on: the selected scene row while the browser has focus.

Returns:
- The scene's index, and whether the browser should handle the shortcut. Paste also works with the
  Scenes folder (or nothing) selected; it then adds at the end
*/
Browser_SceneTarget :: proc(state: ^State, action: Action) -> (scene: int, ok: bool) {
	if !state.browserFocused do return -1, false
	selection := state.browserSelection
	isScene := selection.kind == .Scene && selection.index < len(state.project.scenes)
	#partial switch action {
	case .Paste_Node:
		if !state.hasSceneClipboard do return -1, false
		return isScene ? selection.index : -1, isScene || selection.kind == .Folder || selection.kind == .None
	case .Delete_Node, .Duplicate_Node, .Copy_Node, .Cut_Node, .Rename_Node:
		return selection.index, isScene
	}
	return -1, false
}

/*
A node shortcut used while the browser has focus, as the scene operation it means there.

Returns:
- The operation, and whether the browser takes the action
*/
Browser_RouteAction :: proc(state: ^State, action: Action) -> (Scene_Action, bool) {
	scene, ok := Browser_SceneTarget(state, action)
	if !ok do return {}, false
	op: SceneOp
	#partial switch action {
	case .Delete_Node:    op = .Delete
	case .Duplicate_Node: op = .Duplicate
	case .Copy_Node:      op = .Copy
	case .Cut_Node:       op = .Cut
	case .Paste_Node:     op = .Paste
	case .Rename_Node:    op = .Rename
	}
	return {op, scene}, true
}

// Whether a scene operation changes the project (and so is an undo step)
SceneOp_EditsProject :: proc(op: SceneOp) -> bool {
	switch op {
	case .New, .Duplicate, .Cut, .Paste, .Delete, .Set_Start: return true
	case .Open, .Play, .Rename, .Copy: return false
	}
	return false
}

/*
Does a scene operation from the browser's context menu or keys.

Returns:
- A command to run (Play)
*/
Scene_DoAction :: proc(state: ^State, action: Scene_Action) -> skald.Command(Msg) {
	project := &state.project
	index := action.scene
	valid := index >= 0 && index < len(project.scenes)
	switch action.op {
	case .New:
		at := valid ? index + 1 : -1
		added := Project_AddScene(project, "Scene", at)
		sceneInserted(state, added)
		state.browserOpen[.Scenes] = true
		openScene(state, added)
		selectSceneRow(state, added)
		logLine(state, .Info, fmt.aprintf("Added scene %s", project.scenes[added].name))
		// Name it right away
		startSceneRename(state, added)
	case .Open:
		if valid do openScene(state, index)
	case .Play:
		if valid do return playStart(state, project.scenes[index].name)
	case .Rename:
		if valid do startSceneRename(state, index)
	case .Duplicate:
		if !valid do break
		copy := Project_AddSceneCopy(project, project.scenes[index], index + 1)
		sceneInserted(state, copy)
		selectSceneRow(state, copy)
		logLine(state, .Info, fmt.aprintf("Duplicated %s as %s", project.scenes[index].name, project.scenes[copy].name))
	case .Copy, .Cut:
		if !valid do break
		if state.hasSceneClipboard do SceneDef_Destroy(&state.sceneClipboard)
		state.sceneClipboard = SceneDef_Clone(project.scenes[index])
		state.hasSceneClipboard = true
		if action.op == .Copy {
			logLine(state, .Info, fmt.aprintf("Copied scene %s", project.scenes[index].name))
			break
		}
		if !deleteScene(state, index) {
			// The last scene can't go; it stays copied
		}
	case .Paste:
		if !state.hasSceneClipboard do break
		at := valid ? index + 1 : -1
		pasted := Project_AddSceneCopy(project, state.sceneClipboard, at)
		sceneInserted(state, pasted)
		state.browserOpen[.Scenes] = true
		selectSceneRow(state, pasted)
		logLine(state, .Info, fmt.aprintf("Pasted scene %s", project.scenes[pasted].name))
	case .Delete:
		if valid do deleteScene(state, index)
	case .Set_Start:
		if !valid do break
		Project_SetStartScene(project, index)
		logLine(state, .Info, fmt.aprintf("%s is now the start scene", project.scenes[index].name))
	}
	return {}
}

/*
Ends renaming a scene in the browser: renames it if the name is valid and new (updating what
refers to it), or logs why not.
*/
Scene_CommitRename :: proc(state: ^State) {
	index, text := state.rename.node, strings.trim_space(state.rename.text)
	if index < 0 || index >= len(state.project.scenes) do return
	old := strings.clone(state.project.scenes[index].name, context.temp_allocator)
	if text == old do return
	references, message := Project_RenameScene(&state.project, index, text, &state.scripts)
	if message != "" {
		logLine(state, .Error, fmt.aprintf("Can't rename %s: %s", old, message))
		return
	}
	logLine(state, .Info, references > 0 ? fmt.aprintf("Renamed %s to %s (%d reference%s updated)", old, text, references, references == 1 ? "" : "s") : fmt.aprintf("Renamed %s to %s", old, text))
}

// Frees what the Project Settings dialog's draft owns (it's opened again, or the editor quits)
ProjectSettings_Destroy :: proc(dialog: ^ProjectSettingsDialog) {
	delete(dialog.name)
	delete(dialog.startScene)
	delete(dialog.locale)
	delete(dialog.icon)
	for &g in dialog.globals do GlobalDef_Destroy(&g)
	delete(dialog.globals)
	for &a in dialog.actions do ActionDef_Destroy(&a)
	delete(dialog.actions)
	delete(dialog.newActionName)
	delete(dialog.renameText)
	dialog.name, dialog.startScene, dialog.locale, dialog.icon, dialog.newActionName, dialog.renameText = "", "", "", "", "", ""
	dialog.globals, dialog.actions = nil, nil
}

// Opens the Project Settings dialog on the project's current values, at a tab
ProjectSettings_Open :: proc(state: ^State, tab := ProjectSettingsTab.General) {
	dialog := &state.projectSettings
	exportTarget := dialog.exportTarget
	ProjectSettings_Destroy(dialog)
	p := &state.project
	c := p.background
	dialog^ = {
		open = true,
		name = strings.clone(p.name),
		gameSize = p.gameSize,
		scaleMode = p.scaleMode,
		renderer = p.renderer,
		window = p.window,
		grid = p.grid,
		audioOutput = p.audioOutput,
		background = skald.rgb(u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)),
		startScene = strings.clone(p.startScene),
		locale = strings.clone(p.locale),
		icon = strings.clone(p.icon),
		tab = tab,
		exportTarget = exportTarget,
		exports = p.exports,
		physics = p.physics,
	}
	for g in p.globals do append(&dialog.globals, GlobalDef_Clone(g))
	for a in p.actions do append(&dialog.actions, ActionDef_Clone(a))
	dialog.newActionName = strings.clone("")
	dialog.renameText = strings.clone("")
	dialog.bindingDevice = -1
}

/*
Handles a Project Settings dialog message.

Returns:
- A command to run (an export), and whether `m` was one
*/
ProjectSettings_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	dialog := &state.projectSettings
	if InputSettings_Update(state, m) do return {}, true
	#partial switch v in m {
	case Project_Settings_Tab_Changed:
		dialog.tab = ProjectSettingsTab(v)
	case Project_Settings_Physics_Changed:
		switch v.field {
		case .Pixels_Per_Meter: dialog.physics.pixelsPerMeter = clamp(f32(v.value), 1, 10000)
		case .Gravity_X:        dialog.physics.gravity.x = f32(v.value)
		case .Gravity_Y:        dialog.physics.gravity.y = f32(v.value)
		}
	case Project_Settings_Physics_Debug_Changed:
		dialog.physics.debugDraw = bool(v)
	case Project_Settings_Audio_Changed:
		if v.channels do dialog.audioOutput.channels = clamp(v.value, 0, 8)
		else do dialog.audioOutput.frequency = max(v.value, 0)
	case Project_Settings_Grid_Changed:
		n := int(v.value)
		switch v.field {
		case .Width:         dialog.grid.size.x = clamp(n, e.GRID_SIZE_RANGE[0], e.GRID_SIZE_RANGE[1])
		case .Height:        dialog.grid.size.y = clamp(n, e.GRID_SIZE_RANGE[0], e.GRID_SIZE_RANGE[1])
		case .Major_Every:   dialog.grid.majorEvery = clamp(n, e.GRID_MAJOR_RANGE[0], e.GRID_MAJOR_RANGE[1])
		case .Opacity:       dialog.grid.opacity = clamp(n, 0, 100)
		case .Major_Opacity: dialog.grid.majorOpacity = clamp(n, 0, 100)
		}
	case Global_Added:
		name := strings.trim_space(string(v))
		if name == "" || name == TEXTURE_NONE do break
		known := false
		for g in dialog.globals do if g.script == name do known = true
		if known do break
		append(&dialog.globals, GlobalDef{script = strings.clone(name)})
		dialog.selectedGlobal = len(dialog.globals) - 1
	case Global_Removed:
		i := int(v)
		if i < 0 || i >= len(dialog.globals) do break
		GlobalDef_Destroy(&dialog.globals[i])
		ordered_remove(&dialog.globals, i)
		dialog.selectedGlobal = clamp(dialog.selectedGlobal, 0, max(len(dialog.globals) - 1, 0))
	case Global_Moved:
		j := v.index + v.delta
		if v.index < 0 || v.index >= len(dialog.globals) || j < 0 || j >= len(dialog.globals) do break
		dialog.globals[v.index], dialog.globals[j] = dialog.globals[j], dialog.globals[v.index]
		dialog.selectedGlobal = j
	case Global_Selected:
		dialog.selectedGlobal = int(v)
	case Project_Settings_Physics_Smoothing_Changed:
		dialog.physics.smoothing = bool(v)
	case Project_Settings_Window_Changed:
		switch v.field {
		case .Fullscreen: dialog.window.fullscreen = v.value
		case .VSync:      dialog.window.vsync = v.value
		case .High_DPI:   dialog.window.highDPI = v.value
		}
	case Export_Target_Selected:
		dialog.exportTarget = ExportTarget(v)
	case Export_Target_Enabled:
		dialog.exports.targets[v.target].enabled = v.value
	case Export_Text_Changed:
		if text := ExportField_Text(&dialog.exports.targets[v.target], v.field); text != nil do text^ = FixedText_Make(v.text)
	case Export_Flag_Changed:
		if flag := ExportField_Bool(&dialog.exports.targets[v.target], v.field); flag != nil do flag^ = v.value
	case Export_Target_Run:
		applyProjectSettings(state)
		return skald.cmd_now(Msg(Export_Requested{ExportTarget(v)})), true
	case Export_Cancel_Requested:
		Export_Cancel(state)
	case Project_Settings_Name_Changed:
		delete(dialog.name)
		dialog.name = strings.clone(string(v))
	case Project_Settings_Size_Changed:
		dialog.gameSize[clamp(v.axis, 0, 1)] = clamp(f32(v.value), 16, 16384)
	case Project_Settings_Scale_Changed:
		if mode, ok := reflect.enum_from_name(e.ScaleMode, string(v)); ok do dialog.scaleMode = mode
	case Project_Settings_Renderer_Changed:
		dialog.renderer = e.RenderBackend(v)
	case Project_Settings_Background_Changed:
		dialog.background = skald.Color(v)
	case Project_Settings_Start_Changed:
		delete(dialog.startScene)
		dialog.startScene = strings.clone(string(v))
	case Project_Settings_Locale_Changed:
		delete(dialog.locale)
		dialog.locale = strings.clone(string(v))
	case Project_Settings_Icon_Changed:
		delete(dialog.icon)
		dialog.icon = strings.clone(string(v) == TEXTURE_NONE ? "" : string(v))
	case Project_Settings_Applied:
		applyProjectSettings(state)
		dialog.open = false
		logLine(state, .Info, strings.clone("Project settings changed"))
		// Applied from the Settings dialog, still open: keep editing a fresh copy
		if dialog.embedded && state.settingsDialog.open {
			ProjectSettings_Open(state, dialog.tab)
			dialog.embedded = true
		} else {
			dialog.embedded = false
		}
	case Project_Settings_Cancelled:
		dialog.open = false
		dialog.embedded = false
	case:
		return {}, false
	}
	return {}, true
}

// Sets the project's settings to the dialog's (one undoable step: History_Classify)
@(private="file")
applyProjectSettings :: proc(state: ^State) {
	dialog := &state.projectSettings
	p := &state.project
	name := strings.trim_space(dialog.name)
	if name != "" && name != p.name {
		delete(p.name)
		p.name = strings.clone(name)
	}
	p.gameSize = dialog.gameSize
	p.scaleMode = dialog.scaleMode
	p.renderer = dialog.renderer
	p.window = dialog.window
	p.grid = dialog.grid
	p.audioOutput = dialog.audioOutput
	if dialog.icon != p.icon {
		delete(p.icon)
		p.icon = strings.clone(dialog.icon)
	}
	if locale := strings.trim_space(dialog.locale); locale != p.locale {
		delete(p.locale)
		p.locale = strings.clone(locale)
	}
	if color, ok := e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(dialog.background))); ok do p.background = color
	if Project_FindScene(p, dialog.startScene) >= 0 && dialog.startScene != p.startScene {
		delete(p.startScene)
		p.startScene = strings.clone(dialog.startScene)
	}
	p.exports = dialog.exports
	for &g in p.globals do GlobalDef_Destroy(&g)
	clear(&p.globals)
	for g in dialog.globals do append(&p.globals, GlobalDef_Clone(g))
	for &a in p.actions do ActionDef_Destroy(&a)
	clear(&p.actions)
	for a in dialog.actions do append(&p.actions, ActionDef_Clone(a))
	p.physics = dialog.physics
}

// After a scene was inserted at `index`: the open scene's index moves if it was at or after it
@(private="file")
sceneInserted :: proc(state: ^State, index: int) {
	if index <= state.currentScene && len(state.project.scenes) > 1 do state.currentScene += 1
}

// Removes a scene, keeping the viewport on a valid one. Returns false if it couldn't
@(private="file")
deleteScene :: proc(state: ^State, index: int) -> bool {
	name := strings.clone(state.project.scenes[index].name, context.temp_allocator)
	dangling, message := Project_RemoveScene(&state.project, index)
	if message != "" {
		logLine(state, .Error, fmt.aprintf("Can't delete %s: %s", name, message))
		return false
	}
	state.browserSelection = {kind = .None}
	switch {
	case index < state.currentScene:
		state.currentScene -= 1
	case index == state.currentScene:
		// Show the scene before it (or the new first one)
		state.currentScene = -1
		openScene(state, max(index - 1, 0))
	}
	if dangling > 0 {
		logLine(state, .Warning, fmt.aprintf("Deleted scene %s; %d menu button%s still switch%s to it", name, dangling, dangling == 1 ? "" : "s", dangling == 1 ? "es" : ""))
	} else {
		logLine(state, .Info, fmt.aprintf("Deleted scene %s", name))
	}
	return true
}

// Selects a scene's row in the browser
@(private="file")
selectSceneRow :: proc(state: ^State, index: int) {
	state.browserSelection = {kind = .Scene, folder = .Scenes, index = index}
}

@(private="file")
startSceneRename :: proc(state: ^State, index: int) {
	delete(state.rename.text)
	state.rename = {active = true, target = .Scene, node = index, text = strings.clone(state.project.scenes[index].name)}
	selectSceneRow(state, index)
	state.browserOpen[.Scenes] = true
}
