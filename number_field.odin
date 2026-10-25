package crossfire_editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
A number field: a text box with small flat − and + buttons, used by the inspector and the
Settings dialog. (Skald's `number_input` has large, primary-colored stepper buttons that can't be
restyled.)

While the box has focus it shows what's being typed, kept in `State.numberEdit`, so half-typed
text like "-" or "1." isn't reformatted under the cursor. Each change that parses as a number
applies immediately (clamped to the field's range); otherwise the value waits. When the box loses
focus it shows the value again.
*/

// What a number field edits
NumberTarget :: union {
	NodeField,
	SettingsField,
	ScriptPropTarget,
	// Project Settings: the game's width (0) or height (1)
	GameSizeTarget,
	PhysicsTarget,
	GridTarget,
	// A scene's own gravity (the browser's scene preview): its index and axis
	SceneGravityTarget,
	// The Animation panel's selected animation
	AnimField,
	// One of its frames' times (the frame, from its first)
	AnimDurationTarget,
	// The selected TileMap's frame
	TileMapFrameTarget,
	// The Timeline's clip length, speed and key time
	TimelineNumber,
	// The selected UI control's numbers
	UINumberTarget,
	// The selected NavRegion's or NavAgent's numbers
	NavNumberTarget,
	// Project Settings' transition time
	TransitionTimeTarget,
	// The States tab's numbers: a transition's wait and priority, a state's speed
	SMNumberTarget,
	// The selected camera tool's numbers
	CameraToolNumber,
	// The selected Camera's numbers (camera_edit.odin)
	CameraNumber,
	// Collision from sprite's settings (view state)
	TraceNumber,
	// The shown atlas's padding (atlas_edit.odin)
	AtlasPaddingTarget,
	// A number of an LDtk project (the Level mode's LDtk tab: ldtk_ops.odin)
	LDtkNumberTarget,
	// The Level tab's new size for the selected level (a draft until Resize: view_ldtk_project.odin)
	LevelSizeTarget,
	// The sprite sheet slicer's numbers and frame times (slicer_edit.odin)
	SlicerNumber,
	SlicerDurationTarget,
}

// An LDtk tab's number: the edit it makes, its `number` the field's value (strings: the frame's)
LDtkNumberTarget :: struct {
	edit: LDtk_Edit,
}

// The Level tab's size draft: 0 the width, 1 the height
LevelSizeTarget :: distinct int

GameSizeTarget :: distinct int

// A frame of the Animation panel's selected animation, from its first (its time in ms)
AnimDurationTarget :: distinct int

// Project Settings' physics numbers
PhysicsTarget :: enum {
	Pixels_Per_Meter,
	Gravity_X,
	Gravity_Y,
}

SceneGravityTarget :: struct {
	scene: int,
	axis: int,
}

// Project Settings > Grid's numbers
GridTarget :: enum {
	Width,
	Height,
	Major_Every,
	Opacity,
	Major_Opacity,
}

// A number-typed script field (or one component of a vector field) on the selected node
ScriptPropTarget :: struct {
	// Field name and default (catalog strings, alive while the catalog is)
	name: string,
	defaultValue: string,
	integer: bool,
	// Vector fields: which component this is (0 or 1) and the other one's value; -1 otherwise
	component: int,
	other: f64,
	// Whose value it is (the selected node by default)
	target: PropTarget,
}

// The text typed into a focused number field (part of State)
NumberEdit :: struct {
	id: skald.Widget_ID,
	// Owned
	text: string,
}

// A number field's text box is never narrower than this; the gap between it and its buttons
@(private="file")
NUMBER_FIELD_MIN_BOX :: 40
@(private="file")
NUMBER_FIELD_GAP :: 2

@(private="file")
numberFieldButtonWidth :: proc(th: ^skald.Theme) -> f32 {
	return max(f32(18), th.font.size_md * 1.4)
}

/*
The narrowest a number field is drawn (its smallest text box and the − and + buttons): a row
holding one beside something else must leave it this much to fit `controlWidth`.

Inputs:
- th: The theme (the buttons follow its font size)

Returns:
- The width in pixels
*/
NumberField_MinWidth :: proc(th: ^skald.Theme) -> f32 {
	return NUMBER_FIELD_MIN_BOX + 2 * (numberFieldButtonWidth(th) + NUMBER_FIELD_GAP)
}

/*
Builds a number field.

Inputs:
- key: Unique widget key; the box's id is `hash_id(key)`, the buttons' `key-dec` / `key-inc`
- target: The field it edits
- value: The current value
- step: How much − and + change it
- decimals: Decimals shown
- width: Total width, buttons included, at least `NumberField_MinWidth` (narrower is drawn that
  wide). The box has tight vertical padding (2 px)
- minValue, maxValue: The allowed range
*/
numberField :: proc(
	ctx: ^skald.Ctx(Msg),
	s: ^State,
	key: string,
	target: NumberTarget,
	value, step: f64,
	decimals: int,
	width: f32,
	minValue := min(f64),
	maxValue := max(f64),
) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	id := skald.hash_id(key)
	focused := skald.widget_has_focus(ctx, id)
	editing := s.numberEdit.id == id
	// Focus left with typed text pending: show the value again next frame
	if editing && !focused do skald.send(ctx, Msg(Number_Edit_Ended(id)))

	// Up and Down step it while it has focus (Shift: 10 steps); Left and Right move the caret
	if steps := arrowSteps(ctx, id, upDownOnly = true); steps != 0 {
		if editing do skald.send(ctx, Msg(Number_Edit_Ended(id)))
		skald.send(ctx, NumberTarget_Msg(target, clamp(value + f64(steps) * step, minValue, maxValue)))
	}
	text := editing && focused ? s.numberEdit.text : formatNumber(value, decimals)
	buttonWidth, gap := numberFieldButtonWidth(th), f32(NUMBER_FIELD_GAP)

	Payload :: struct {
		target: NumberTarget,
		id: skald.Widget_ID,
		lo, hi: f64,
	}
	input := skald.text_input(ctx, text, Payload{target, id, minValue, maxValue},
		proc(p: Payload, v: string) -> Msg { return Number_Text_Changed{p.target, p.id, v, p.lo, p.hi} },
		id = id, width = max(width - 2 * (buttonWidth + gap), NUMBER_FIELD_MIN_BOX), padding = tk.fieldPadding)

	stepButton :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, width: f32) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		return skald.button(ctx, label, msg,
			id = skald.hash_id(key),
			bg = th.color.surface, fg = th.color.fg_muted,
			width = width, padding = {0, tk.hair}, font_size = th.font.size_sm, radius = th.radius.sm)
	}
	return skald.row(
		input,
		stepButton(ctx, fmt.tprintf("%s-dec", key), "−", NumberTarget_Msg(target, clamp(value - step, minValue, maxValue)), buttonWidth),
		stepButton(ctx, fmt.tprintf("%s-inc", key), "+", NumberTarget_Msg(target, clamp(value + step, minValue, maxValue)), buttonWidth),
		spacing = gap,
		cross_align = .Center,
	)
}

// The message that sets a number field's value
NumberTarget_Msg :: proc(target: NumberTarget, value: f64) -> Msg {
	switch t in target {
	case NodeField:     return Node_Field_Changed{t, value}
	case SettingsField: return Settings_Value_Changed{t, value}
	case GameSizeTarget: return Project_Settings_Size_Changed{int(t), value}
	case PhysicsTarget:  return Project_Settings_Physics_Changed{t, value}
	case GridTarget:     return Project_Settings_Grid_Changed{t, value}
	case SceneGravityTarget: return Scene_Gravity_Changed{t.scene, t.axis, value}
	case AnimField:      return Anim_Field_Changed{t, value}
	case AnimDurationTarget: return Anim_Duration_Changed{int(t), value}
	case TileMapFrameTarget: return TileMap_Setting_Changed{field = .Frame, value = value}
	case UINumberTarget: return UI_Setting_Changed{field = UIField(t), value = value}
	case NavNumberTarget: return Nav_Setting_Changed{field = NavField(t), value = value}
	case TransitionTimeTarget: return Project_Settings_Transition_Changed{field = .Duration, value = value}
	case SMNumberTarget:
		switch t {
		case .After: return SM_Changed{op = .Transition_After, number = f32(value)}
		case .Priority: return SM_Changed{op = .Transition_Priority, number = f32(value)}
		case .Speed: return SM_Changed{op = .State_Speed, number = f32(value)}
		}
	case CameraToolNumber: return Camera_Tool_Changed{field = CameraToolField(t), value = f32(value)}
	case CameraNumber: return Camera_Changed{field = CameraField(t), value = f32(value)}
	case TraceNumber: return Trace_Setting_Changed{field = TraceField(t), value = f32(value)}
	case AtlasPaddingTarget: return Atlas_Padding_Changed(int(value))
	case SlicerNumber: return Slicer_Number_Changed{t, value}
	case SlicerDurationTarget: return Slicer_Duration_Changed{int(t), value}
	case LevelSizeTarget: return Level_Size_Typed{axis = int(t), value = value}
	case LDtkNumberTarget:
		edit := t.edit
		edit.number = value
		return edit
	case TimelineNumber:
		ops := [TimelineNumber]TimelineOp{.Length = .Clip_Length, .Speed = .Speed, .Key_Time = .Key_Time}
		return Timeline_Changed{op = ops[t], number = f32(value)}
	case ScriptPropTarget:
		text: string
		switch {
		case t.component == 0: text = fmt.tprintf("%v, %v", f32(value), f32(t.other))
		case t.component == 1: text = fmt.tprintf("%v, %v", f32(t.other), f32(value))
		case t.integer:        text = fmt.tprintf("%d", int(value))
		case:                  text = fmt.tprintf("%v", f32(value))
		}
		return Script_Prop_Changed{name = t.name, value = text, defaultValue = t.defaultValue, target = t.target}
	}
	return nil
}

/*
Handles typing in a number field: keeps the text, and returns the message that applies it if it
parses as a number (nil otherwise).
*/
NumberEdit_Update :: proc(state: ^State, v: Number_Text_Changed) -> Msg {
	delete(state.numberEdit.text)
	state.numberEdit = {id = v.id, text = strings.clone(v.text)}
	value, ok := strconv.parse_f64(strings.trim_space(v.text))
	if !ok do return nil
	return NumberTarget_Msg(v.target, clamp(value, v.lo, v.hi))
}

// "12", "0.40": a fixed number of decimals, without "-0"
@(private="file")
formatNumber :: proc(value: f64, decimals: int) -> string {
	text := fmt.tprintf(fmt.tprintf("%%.%df", max(decimals, 0)), value)
	if strings.trim_left(text, "-0.") == "" do return text[1:] if text[0] == '-' else text
	return text
}
