package editor

import "core:reflect"
import "core:strings"
import e "engine:."
import "gui:skald"

/*
The project's input actions (the engine's input.odin): named inputs ("jump", "ui_left") that keys,
mouse buttons, gamepad buttons and stick directions trigger; scripts ask about them with
`e.Input_IsActionPressed("jump")` and the rest. Edited in Project Settings > Input (a draft in
`ProjectSettingsDialog`, applied as one `.Project` undo step), saved in project.xml as `<action>`.
The view is view_project_input.odin.
*/

// An action: its name (owned), its deadzone for sticks and triggers, and what triggers it
ActionDef :: struct {
	name: string,
	deadzone: f32,
	bindings: [dynamic]e.InputBinding,
}

ActionDef_Clone :: proc(a: ActionDef) -> ActionDef {
	copy := ActionDef{name = strings.clone(a.name), deadzone = a.deadzone}
	append(&copy.bindings, ..a.bindings[:])
	return copy
}

ActionDef_Destroy :: proc(a: ^ActionDef) {
	delete(a.name)
	delete(a.bindings)
}

// Whether two action lists are the same
actionsEqual :: proc(a, b: []ActionDef) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if x.name != y.name || x.deadzone != y.deadzone || len(x.bindings) != len(y.bindings) do return false
		for binding, k in x.bindings do if binding != y.bindings[k] do return false
	}
	return true
}

/*
The actions a new project starts with, like Godot's ui_* actions: moving with the arrow keys,
WASD, the d-pad or the left stick, accepting and cancelling (owned).
*/
DefaultActions :: proc() -> [dynamic]ActionDef {
	actions := make([dynamic]ActionDef)
	add :: proc(actions: ^[dynamic]ActionDef, name: string, bindings: ..e.InputBinding) {
		a := ActionDef{name = strings.clone(name), deadzone = e.DEFAULT_ACTION_DEADZONE}
		append(&a.bindings, ..bindings)
		append(actions, a)
	}
	add(&actions, "ui_left", e.KeyBinding{.Left}, e.KeyBinding{.A}, e.GamepadButtonBinding{.DpadLeft, -1}, e.GamepadAxisBinding{.LeftX, -1, -1})
	add(&actions, "ui_right", e.KeyBinding{.Right}, e.KeyBinding{.D}, e.GamepadButtonBinding{.DpadRight, -1}, e.GamepadAxisBinding{.LeftX, 1, -1})
	add(&actions, "ui_up", e.KeyBinding{.Up}, e.KeyBinding{.W}, e.GamepadButtonBinding{.DpadUp, -1}, e.GamepadAxisBinding{.LeftY, -1, -1})
	add(&actions, "ui_down", e.KeyBinding{.Down}, e.KeyBinding{.S}, e.GamepadButtonBinding{.DpadDown, -1}, e.GamepadAxisBinding{.LeftY, 1, -1})
	add(&actions, "ui_accept", e.KeyBinding{.Enter}, e.KeyBinding{.Space}, e.GamepadButtonBinding{.South, -1})
	add(&actions, "ui_cancel", e.KeyBinding{.Escape}, e.GamepadButtonBinding{.East, -1})
	return actions
}

// Why a name can't be an action's (index: the action being renamed, -1 for a new one; "" if it can)
ActionNameProblem :: proc(actions: []ActionDef, index: int, name: string) -> string {
	trimmed := strings.trim_space(name)
	if trimmed == "" do return "Give it a name"
	if trimmed != name do return "No spaces at the ends"
	for a, i in actions do if i != index && a.name == name do return "There's already an action with that name"
	return ""
}

/*
The engine key for a key Skald reports (the editor captures bindings through Skald), or .Unknown.
Skald names keys like the engine except `Page_Up`, `Left_Bracket` (no underscores in the
engine) and `N0`..`N9` (`Num0`..`Num9`).
*/
EngineKeyFor :: proc(key: skald.Key) -> e.Key {
	name, _ := reflect.enum_name_from_value(key)
	if len(name) == 2 && name[0] == 'N' && name[1] >= '0' && name[1] <= '9' {
		name = strings.concatenate({"Num", name[1:]}, context.temp_allocator)
	} else {
		name, _ = strings.remove_all(name, "_", context.temp_allocator)
	}
	if k, ok := reflect.enum_from_name(e.Key, name); ok do return k
	return .Unknown
}

/*
What the Input tab's capture saw this frame: a key (or a modifier on its own), a mouse button or
the wheel. Clears what it used from the input so nothing else reacts to it.

Returns:
- The binding, and false if nothing was pressed (Escape cancels: `cancelled`)
*/
Input_CaptureBinding :: proc(ctx: ^skald.Ctx(Msg), previousModifiers: skald.Modifiers) -> (binding: e.InputBinding, captured, cancelled: bool) {
	pressed := ctx.input.keys_pressed
	if .Escape in pressed && ctx.input.modifiers == {} {
		ctx.input.keys_pressed = {}
		return nil, false, true
	}
	for key in skald.Key {
		if key not_in pressed do continue
		if k := EngineKeyFor(key); k != .Unknown {
			ctx.input.keys_pressed = {}
			ctx.input.text = ""
			return e.KeyBinding{k}, true, false
		}
	}
	// A modifier pressed on its own (Skald doesn't tell left from right: the left one)
	added := ctx.input.modifiers - previousModifiers
	switch {
	case .Shift in added: return e.KeyBinding{.LeftShift}, true, false
	case .Ctrl in added:  return e.KeyBinding{.LeftCtrl}, true, false
	case .Alt in added:   return e.KeyBinding{.LeftAlt}, true, false
	case .Super in added: return e.KeyBinding{.LeftSuper}, true, false
	}
	buttons := [?]struct { skald: skald.Mouse_Button, engine: e.MouseButton }{{.Left, .Left}, {.Middle, .Middle}, {.Right, .Right}}
	for b in buttons {
		if ctx.input.mouse_pressed[b.skald] {
			ctx.input.mouse_pressed[b.skald] = false
			return e.MouseBinding{b.engine}, true, false
		}
	}
	scroll := ctx.input.scroll
	if scroll.y != 0 || scroll.x != 0 {
		ctx.input.scroll = {}
		switch {
		case scroll.y > 0: return e.MouseBinding{.WheelUp}, true, false
		case scroll.y < 0: return e.MouseBinding{.WheelDown}, true, false
		case scroll.x < 0: return e.MouseBinding{.WheelLeft}, true, false
		case:              return e.MouseBinding{.WheelRight}, true, false
		}
	}
	return nil, false, false
}

/*
Handles the Input tab's messages (on the dialog's draft).

Returns:
- Whether `m` was one of them
*/
InputSettings_Update :: proc(state: ^State, m: Msg) -> bool {
	d := &state.projectSettings
	selected := d.selectedAction >= 0 && d.selectedAction < len(d.actions) ? &d.actions[d.selectedAction] : nil
	#partial switch v in m {
	case Input_New_Name_Changed:
		delete(d.newActionName)
		d.newActionName = strings.clone(string(v))
	case Input_Action_Added:
		name := d.newActionName
		if ActionNameProblem(d.actions[:], -1, name) != "" do break
		append(&d.actions, ActionDef{name = strings.clone(name), deadzone = e.DEFAULT_ACTION_DEADZONE})
		d.selectedAction = len(d.actions) - 1
		delete(d.newActionName)
		d.newActionName = strings.clone("")
	case Input_Defaults_Added:
		// The default ui_* actions the draft doesn't have yet
		defaults := DefaultActions()
		defer delete(defaults)
		for &a in defaults {
			taken := false
			for b in d.actions do if b.name == a.name do taken = true
			if taken {
				ActionDef_Destroy(&a)
			} else {
				append(&d.actions, a)
			}
		}
	case Input_Action_Selected:
		d.selectedAction = int(v)
		d.capturing = false
	case Input_Action_Removed:
		i := int(v)
		if i < 0 || i >= len(d.actions) do break
		ActionDef_Destroy(&d.actions[i])
		ordered_remove(&d.actions, i)
		d.selectedAction = clamp(d.selectedAction, 0, max(len(d.actions) - 1, 0))
	case Input_Action_Moved:
		j := v.index + v.delta
		if v.index < 0 || v.index >= len(d.actions) || j < 0 || j >= len(d.actions) do break
		d.actions[v.index], d.actions[j] = d.actions[j], d.actions[v.index]
		d.selectedAction = j
	case Input_Action_Renamed:
		delete(d.renameText)
		d.renameText = strings.clone(string(v))
		if selected == nil || ActionNameProblem(d.actions[:], d.selectedAction, string(v)) != "" do break
		delete(selected.name)
		selected.name = strings.clone(string(v))
	case Input_Deadzone_Changed:
		if selected != nil do selected.deadzone = clamp(f32(v), 0, 0.99)
	case Input_Binding_Added:
		d.capturing = false
		if selected == nil || v.binding == nil do break
		for b in selected.bindings do if b == v.binding do return true
		append(&selected.bindings, v.binding)
	case Input_Binding_Removed:
		if selected == nil || int(v) < 0 || int(v) >= len(selected.bindings) do break
		ordered_remove(&selected.bindings, int(v))
	case Input_Capture_Started:
		d.capturing = selected != nil
		d.captureModifiers = skald.Modifiers(v)
	case Input_Capture_Cancelled:
		d.capturing = false
	case Input_Device_Changed:
		d.bindingDevice = int(v)
	case:
		return false
	}
	return true
}
