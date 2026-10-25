package crossfire_editor

import "core:fmt"
import "gui:skald"

/*
Dragging editor things into code: the panels' side of code_drops.odin. Scene tree nodes and
browser assets keep their own drags (they also drop into the scene tree and the viewport:
`treeDrag`, `assetDrag`); everything else (inspector property labels and events, animations,
states and parameters, input actions, groups, buses, Timeline clips, scenes) starts one here
with a `DropSource` describing it:

- `CodeDrag_From`: a widget the panel already has (a button, a strip) starts a drag when pressed
  while a code tab shows; `CodeDrag_Zone` wraps a label to make one; `CodeDrag_Handle` is a grip
  for things shown in a dropdown or a canvas (the Animation panel's, the Timeline's clips, the
  selected state), drawn only while a code tab shows.
- `State.codeDrag` holds the source (cloned) from the press; past CODE_DRAG_THRESHOLD it's a drag
  (`CodeDrag_View` draws its label by the pointer), and the release over the code tab drops it
  (`Code_Source_Dropped`, Shift held: the choices' menu), anywhere else cancels.
- **Input actions are in a dialog** (Project Settings > Input, modal): it hides while one of its
  actions is dragged, so the code tab under it takes the drop, and shows again after. A new
  action not applied yet has no constant: its name goes in as text.
*/

// How far the mouse moves with the button down before a press becomes a drag into code
CODE_DRAG_THRESHOLD :: 5

// A press on something that can be dragged into code (its source's strings live for the frame)
Code_Drag_Pressed :: struct {
	source: DropSource,
	start:  [2]f32,
	// A browser row whose click waited for this (a scene: opening it would hide the code tab),
	// clicked when it's released without a drag
	browserRow: Maybe(int),
}
// The mouse moved far enough: it's a drag
Code_Drag_Started :: struct {}
// Released anywhere but the code tab
Code_Drag_Cancelled :: struct {}
// Released over the code tab (window coordinates); `menu`: Shift was held (the choices' menu)
Code_Source_Dropped :: struct {
	mouse: [2]f32,
	menu:  bool,
}
// A drop's menu was picked from: what it wrote (for the Console; lives for the frame)
Code_Drop_Chosen :: struct {
	message: string,
}

// The drag into code under way (State.codeDrag)
CodeDrag :: struct {
	pressed, active: bool,
	start: [2]f32,
	// What's dragged (owned)
	source: DropSource,
	// The browser row clicked if it's released without a drag (Code_Drag_Pressed's)
	browserRow: Maybe(int),
}

// Ends a drag into code (frees its source)
CodeDrag_Clear :: proc(state: ^State) {
	DropSource_Destroy(&state.codeDrag.source)
	state.codeDrag = {}
}

/*
The drag's messages, and a drop's menu pick.

Returns:
- A command, and whether `m` was one of them
*/
CodeDrag_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Code_Drag_Pressed:
		CodeDrag_Clear(state)
		state.codeDrag = {pressed = true, start = v.start, source = DropSource_Clone(v.source), browserRow = v.browserRow}
	case Code_Drag_Started:
		state.codeDrag.active = true
	case Code_Drag_Cancelled:
		CodeDrag_Clear(state)
	case Code_Source_Dropped:
		source := state.codeDrag.source
		state.codeDrag.source = {}
		CodeDrag_Clear(state)
		defer DropSource_Destroy(&source)
		message, added := CodeEditor_Drop(state, CodeTabs_Active(state), v.mouse, source, v.menu)
		if message != "" do logLine(state, added ? .Info : .Warning, fmt.aprintf("%s", message))
	case Code_Drop_Chosen:
		logLine(state, .Info, fmt.aprintf("%s", v.message))
	case:
		return {}, false
	}
	return {}, true
}

// Whether the dialogs hide for the drag: an input action dragged out of Project Settings
CodeDrag_HidesDialogs :: proc(s: ^State) -> bool {
	return s.codeDrag.active && s.codeDrag.source.kind == .Action
}

// Whether a press at the mouse may start a drag into code: a code tab shows, nothing's being
// dragged, and no dialog covers the point (a dialog's own widgets are fine)
@(private="file")
pressStarts :: proc(ctx: ^skald.Ctx(Msg), s: ^State) -> bool {
	if s.codeTab == 0 || s.codeDrag.pressed || !ctx.input.mouse_pressed[.Left] do return false
	modal := ctx.widgets.modal_rect_prev
	if modal.w > 0 do return pointIn(modal, ctx.input.mouse_pos)
	return !skald.mouse_over_overlay(ctx)
}

/*
Starts a drag of `source` into code when the widget `id` (where it was drawn last frame) is
pressed while a code tab shows. The press still reaches the widget (a button's click, a row's
selection): only moving away with the button down makes it a drag.
*/
CodeDrag_From :: proc(ctx: ^skald.Ctx(Msg), s: ^State, id: skald.Widget_ID, source: DropSource) {
	if !pressStarts(ctx, s) do return
	st, drawn := ctx.widgets.states[id]
	if !drawn || !pointIn(st.last_rect, ctx.input.mouse_pos) do return
	skald.send(ctx, Msg(Code_Drag_Pressed{source = source, start = ctx.input.mouse_pos}))
}

// A view (a label) that drags `source` into code; `key` is its widget key (tests drag it)
CodeDrag_Zone :: proc(ctx: ^skald.Ctx(Msg), s: ^State, child: skald.View, key: string, source: DropSource) -> skald.View {
	id := skald.hash_id(key)
	CodeDrag_From(ctx, s, id, source)
	return skald.zone(ctx, child, id)
}

// A grip to drag `source` into code by, while a code tab shows (else nothing)
CodeDrag_Handle :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: string, source: DropSource) -> skald.View {
	if s.codeTab == 0 do return skald.View(skald.View_Spacer{size = 0})
	th := ctx.theme
	grip := CodeDrag_Zone(ctx, s, uiText(th, .Label, ICON_GRIP), key, source)
	return skald.tooltip(ctx, grip, fmt.tprintf("Drag %s into the code (Shift on release: choices)", DropSource_Describe(s, source)), id = skald.hash_id(fmt.tprintf("%s-tip", key)))
}

/*
The drag's label by the pointer, and its end: dropped on the code tab or cancelled. Called once
per frame from `view`, after the panels.
*/
CodeDrag_View :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	none := skald.View(skald.View_Spacer{size = 0})
	if !s.codeDrag.pressed do return none
	th := ctx.theme
	mouse := ctx.input.mouse_pos
	codeArea := ctx.widgets.states[skald.hash_id(CODE_EDITOR_KEY)].last_rect
	overCode := s.codeTab > 0 && pointIn(codeArea, mouse)
	if !ctx.input.mouse_buttons[.Left] {
		if s.codeDrag.active && overCode {
			skald.send(ctx, Msg(Code_Source_Dropped{mouse = mouse, menu = .Shift in ctx.input.modifiers}))
		} else {
			skald.send(ctx, Msg(Code_Drag_Cancelled{}))
			// Not a drag after all: the click it held back
			if row, held := s.codeDrag.browserRow.?; held && !s.codeDrag.active do skald.send(ctx, Msg(Browser_Selected(row)))
		}
		return none
	}
	if !s.codeDrag.active {
		d := mouse - s.codeDrag.start
		if d.x * d.x + d.y * d.y >= CODE_DRAG_THRESHOLD * CODE_DRAG_THRESHOLD do skald.send(ctx, Msg(Code_Drag_Started{}))
		return none
	}
	label := fmt.tprintf("%s  %s", ICON_FILE_CODE, DropSource_Describe(s, s.codeDrag.source))
	hint := overCode ? "drop into the code (Shift: choices)" : "drag into a script's code tab"
	skald.cursor_request_top(ctx, overCode ? .Move : .Not_Allowed)
	return skald.overlay({mouse.x + 14, mouse.y + 10, 0, 0},
		skald.col(
			skald.text(label, overCode ? th.color.on_primary : th.color.fg, th.font.size_sm),
			skald.text(hint, overCode ? th.color.on_primary : th.color.fg_muted, th.font.size_xs),
			padding = th.spacing.xs,
			bg = overCode ? th.color.primary : th.color.elevated,
			radius = th.radius.sm,
		),
		no_shadow = true, pin = true)
}
