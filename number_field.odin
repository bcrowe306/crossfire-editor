package editor

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
}

GameSizeTarget :: distinct int

// Project Settings' physics numbers
PhysicsTarget :: enum {
	Pixels_Per_Meter,
	Gravity_X,
	Gravity_Y,
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
}

// The text typed into a focused number field (part of State)
NumberEdit :: struct {
	id: skald.Widget_ID,
	// Owned
	text: string,
}

/*
Builds a number field.

Inputs:
- key: Unique widget key; the box's id is `hash_id(key)`, the buttons' `key-dec` / `key-inc`
- target: The field it edits
- value: The current value
- step: How much − and + change it
- decimals: Decimals shown
- width: Total width, buttons included. The box has tight vertical padding (2 px)
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
	th := ctx.theme
	id := skald.hash_id(key)
	focused := skald.widget_has_focus(ctx, id)
	editing := s.numberEdit.id == id
	// Focus left with typed text pending: show the value again next frame
	if editing && !focused do skald.send(ctx, Msg(Number_Edit_Ended(id)))

	text := editing && focused ? s.numberEdit.text : formatNumber(value, decimals)
	buttonWidth := max(f32(18), th.font.size_md * 1.4)
	gap := f32(2)

	Payload :: struct {
		target: NumberTarget,
		id: skald.Widget_ID,
		lo, hi: f64,
	}
	input := skald.text_input(ctx, text, Payload{target, id, minValue, maxValue},
		proc(p: Payload, v: string) -> Msg { return Number_Text_Changed{p.target, p.id, v, p.lo, p.hi} },
		id = id, width = max(width - 2 * (buttonWidth + gap), 40), padding = {th.spacing.sm, 2})

	stepButton :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, width: f32) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg,
			id = skald.hash_id(key),
			bg = th.color.surface, fg = th.color.fg_muted,
			width = width, padding = {0, 1}, font_size = th.font.size_sm, radius = th.radius.sm)
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
	case ScriptPropTarget:
		text: string
		switch {
		case t.component == 0: text = fmt.tprintf("%v, %v", f32(value), f32(t.other))
		case t.component == 1: text = fmt.tprintf("%v, %v", f32(t.other), f32(value))
		case t.integer:        text = fmt.tprintf("%d", int(value))
		case:                  text = fmt.tprintf("%v", f32(value))
		}
		return Script_Prop_Changed{name = t.name, value = text, defaultValue = t.defaultValue}
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
