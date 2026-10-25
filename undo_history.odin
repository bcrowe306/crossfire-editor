package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The History tab: the undo history as a list (TODO.md's "UI and UX" round "Feedback", 2026-10-25;
Edit > Undo History shows it).

The rows are the project as it was opened ("Opened"), then every step on the undo stack, oldest
first, then the undone steps that can be redone (muted, newest undone first). The current step,
where the project is now, is selected. A click on a row undoes or redoes to it
(`History_JumpTo`): one step at a time through `History_Undo` / `History_Redo`, so each step's
mode, scene and selection come back as Ctrl+Z would bring them. An LDtk step waiting for the user's
answer (its file changed outside) stops the jump there.

Keys: the list `history-list`, its rows `history-row-<i>` (0 the opened project); driver check
`history <steps> <current>`. Tests: `undo_history_jumps_to_a_step` (notifications_test.odin);
tests/ui/feedback.script.
*/

// A History row clicked: undo or redo until that many steps are on the undo stack
History_Jump :: distinct int

/*
Undoes or redoes until `target` steps are on the undo stack.

Inputs:
- s: The editor state
- target: The undo stack's length wanted (0: every step undone)

Returns:
- How many steps were undone (negative) or redone
*/
History_JumpTo :: proc(s: ^State, target: int) -> int {
	moved := 0
	target := clamp(target, 0, len(s.history.undo) + len(s.history.redo))
	for len(s.history.undo) > target {
		if _, ok := History_Undo(s); !ok || s.level.conflict.open do break
		moved -= 1
	}
	for len(s.history.undo) < target && len(s.history.redo) > 0 {
		if _, ok := History_Redo(s); !ok || s.level.conflict.open do break
		moved += 1
	}
	return moved
}

// The History tab's messages (the jump also follows the LDtk levels and the game's shapes, as Undo does)
UndoHistory_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case History_Jump:
		shapes := state.project.physics.debugDraw
		moved := History_JumpTo(state, int(v))
		if moved != 0 do logLine(state, .Info, fmt.aprintf("%s %d step%s", moved < 0 ? "Undid" : "Redid", abs(moved), abs(moved) == 1 ? "" : "s"))
		if state.project.physics.debugDraw != shapes do Live_SetShapes(state, state.project.physics.debugDraw)
		// `update` follows the LDtk levels after it, as after an undo
		return true
	}
	return false
}

// The History tab: the steps, the current one selected, or an empty state
UndoHistoryPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	tk := uiTokens(ctx)
	h := &s.history
	if len(h.undo) == 0 && len(h.redo) == 0 {
		return emptyState(ctx, "Nothing to undo yet: every edit shows here as a step, and a click on one goes back to it.")
	}
	total := 1 + len(h.undo) + len(h.redo)
	rows := make([]ListRow, total, context.temp_allocator)
	current := len(h.undo)
	for i in 0 ..< total {
		label := "Opened"
		undone := i > current
		if i >= 1 && i <= len(h.undo) {
			label = h.undo[i - 1].label
		} else if undone {
			// The redo stack's newest undone step is its last
			label = h.redo[len(h.redo) - (i - current)].label
		}
		if strings.trim_space(label) == "" do label = "Edit"
		rows[i] = {
			row = {label = label, selected = i == current, labelColor = undone ? th.color.fg_muted : {}},
			key = fmt.tprintf("history-row-%d", i),
			pick = Msg(History_Jump(i)),
		}
	}
	header := skald.row(
		uiText(th, .Muted, fmt.tprintf("%d step%s, %d undone: click one to go back to it", len(h.undo), len(h.undo) == 1 ? "" : "s", len(h.redo))),
		padding = tk.panelPadding,
		cross_align = .Center,
	)
	listView, _ := rowList(ctx, "history-list", rows, tk.rowHeight)
	return skald.col(
		header,
		skald.flex(1, skald.scroll(ctx, {0, 0}, listView, id = skald.hash_id("history-scroll"), reveal_focus = false)),
		cross_align = .Stretch,
	)
}
