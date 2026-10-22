package crossfire_editor

import sdl "vendor:sdl3"

/*
A scene's own settings (the engine's `e.SceneSettings`), edited in the browser's scene preview
(view_browser_info.odin): the layers drawn without the camera (HUDs, menus), a background color
instead of the project's, and a gravity instead of the project's. They're written on the scene
file's root element (`SceneToXML`); each edit is a `.Project` undo step (History_Classify), the
project snapshot holding every scene.
*/

// The scene preview's settings messages: true if handled
SceneSettings_Update :: proc(state: ^State, m: Msg) -> bool {
	scene := proc(state: ^State, index: int) -> ^SceneDef {
		if index < 0 || index >= len(state.project.scenes) || Scene_IsComponent(&state.project.scenes[index]) do return nil
		return &state.project.scenes[index]
	}
	#partial switch v in m {
	case Scene_Screen_Layer_Toggled:
		if s := scene(state, v.scene); s != nil {
			if v.layer in s.settings.screenLayers do s.settings.screenLayers -= {v.layer}
			else do s.settings.screenLayers += {v.layer}
		}
	case Scene_Background_Changed:
		if s := scene(state, v.scene); s != nil {
			s.settings.hasBackground = v.on
			s.settings.background = v.color
			// Starting from the project's color, so turning it on changes nothing yet
			if v.on && v.fromProject do s.settings.background = state.project.background
		}
	case Scene_Gravity_Toggled:
		if s := scene(state, v.scene); s != nil {
			s.settings.hasGravity = bool(v.on)
			if v.on && s.settings.gravity == {} do s.settings.gravity = state.project.physics.gravity
		}
	case Scene_Gravity_Changed:
		if s := scene(state, v.scene); s != nil && s.settings.hasGravity do s.settings.gravity[clamp(v.axis, 0, 1)] = f32(v.value)
	case:
		return false
	}
	return true
}

// What a scene settings message edits, for History_Classify (scope .None for other messages)
SceneSettings_Classify :: proc(state: ^State, m: Msg) -> (index: int, field: string, ok: bool) {
	#partial switch v in m {
	case Scene_Screen_Layer_Toggled: return v.scene, "screen layers", true
	case Scene_Background_Changed:   return v.scene, "background", true
	case Scene_Gravity_Toggled:      return v.scene, "gravity", true
	case Scene_Gravity_Changed:      return v.scene, "gravity", true
	case Scene_Lighting_Changed:     return v.scene, "lighting", true
	}
	return -1, "", false
}

// A scene's gravity in the project's units when it has none of its own
SceneSettings_Gravity :: proc(project: ^Project, scene: ^SceneDef) -> [2]f32 {
	return scene.settings.hasGravity ? scene.settings.gravity : project.physics.gravity
}

// Its background: its own, else the project's
SceneSettings_Background :: proc(project: ^Project, scene: ^SceneDef) -> sdl.Color {
	return scene.settings.hasBackground ? scene.settings.background : project.background
}
