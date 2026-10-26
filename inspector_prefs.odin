package crossfire_editor

import "core:encoding/ini"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "gui:skald"

/*
Pinned properties and remembered sections in the inspector (TODO.md's "UI and UX" round
"Workflow", 2026-10-25), per node type.

- **Pins:** hovering a property row of the one-node inspector shows a pin beside its label
  (`inspector-pin-<label>`); a pinned row moves to a "Pinned" section at the top, in the order
  pinned, for every node of that type, and its pin (always shown there) unpins it
  (`Inspector_Pin_Toggled`). Rows are pinned by their label (`inspectorRow`'s), so any row built
  with it can be pinned: the base rows, the kinds' rows, script fields.
- **Sections:** the inspector's "Node" section (name to groups) and its kind's section (a Sprite's
  rows...) have headers that collapse them (`inspector-section-<Node | Kind>`,
  `Inspector_Section_Toggled`); a collapsed section is remembered per node type. A collapsed
  section's pinned rows still show under Pinned. The Script and Events sections keep their own
  headers (Events' Show / Hide is the editor's, not per type).
- **Saved per project** in `.editor/inspector.ini`, a section per node type (`[Sprite]`) with
  `pinned = Position X|Texture` and `collapsed = Node`, written when they change, read when the
  project opens (`InspectorPrefs_Load`).
- How rows reach the Pinned section: `inspectorView` sets `inspectorPins` while it builds; a
  pinned row's `inspectorRow` keeps the row there and returns `pinnedPlaceholder`, which the
  assembly drops.
*/

INSPECTOR_PREFS_FILE :: ".editor/inspector.ini"

// Per node type: its pinned rows' labels, in pin order, and its collapsed sections (all owned)
InspectorPrefs :: struct {
	pinned: [NodeKind][dynamic]string,
	collapsed: [NodeKind][dynamic]string,
}

// A row's pin clicked: pins or unpins `label` for nodes of `kind`
Inspector_Pin_Toggled :: struct {
	kind: NodeKind,
	label: string,
}
// A section's header clicked: collapses or opens it for nodes of `kind`
Inspector_Section_Toggled :: struct {
	kind: NodeKind,
	section: string,
}

/*
What a pinned row leaves in its place: a spacer of size -0 (nothing, even inside a kind's own
column), which `Inspector_DropPlaceholders` drops from the inspector's rows.
*/
pinnedPlaceholder :: proc() -> skald.View {
	return skald.View_Spacer{size = math.copy_sign_f32(0, -1)}
}

// The rows being pinned while `inspectorView` builds (per thread: tests build views in parallel)
@(thread_local)
inspectorPins: struct {
	active: bool,
	kind: NodeKind,
	node: int,
	labels: []string,
	rows: []skald.View,
	filled: []bool,
}

// Whether a node type has a label pinned (its index in the pin order, -1 when not)
InspectorPrefs_PinIndex :: proc(p: ^InspectorPrefs, kind: NodeKind, label: string) -> int {
	for l, i in p.pinned[kind] do if l == label do return i
	return -1
}

// Whether a node type's section is collapsed
InspectorPrefs_Collapsed :: proc(p: ^InspectorPrefs, kind: NodeKind, section: string) -> bool {
	for c in p.collapsed[kind] do if c == section do return true
	return false
}

// Adds or removes a string of an owned list
@(private="file")
toggleIn :: proc(list: ^[dynamic]string, value: string) {
	for v, i in list do if v == value {
		delete(v)
		ordered_remove(list, i)
		return
	}
	append(list, strings.clone(value))
}

/*
The file's text: a section per node type that has pins or collapsed sections.

Returns:
- The text (temp allocated)
*/
InspectorPrefs_Text :: proc(p: ^InspectorPrefs) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "; The inspector's pinned properties and collapsed sections per node type (Crossfire Editor)\n")
	for kind in NodeKind {
		if len(p.pinned[kind]) == 0 && len(p.collapsed[kind]) == 0 do continue
		fmt.sbprintf(&b, "[%v]\n", kind)
		if len(p.pinned[kind]) > 0 do fmt.sbprintf(&b, "pinned = %s\n", strings.join(p.pinned[kind][:], "|", context.temp_allocator))
		if len(p.collapsed[kind]) > 0 do fmt.sbprintf(&b, "collapsed = %s\n", strings.join(p.collapsed[kind][:], "|", context.temp_allocator))
	}
	return strings.to_string(b)
}

// Reads the file's text into `p` (replacing it); unknown types and keys are skipped
InspectorPrefs_Parse :: proc(p: ^InspectorPrefs, text: string) {
	InspectorPrefs_Clear(p)
	it := ini.iterator_from_string(text)
	for key, value in ini.iterate(&it) {
		kind, ok := reflect.enum_from_name(NodeKind, it.section)
		if !ok do continue
		list: ^[dynamic]string
		switch key {
		case "pinned":    list = &p.pinned[kind]
		case "collapsed": list = &p.collapsed[kind]
		case: continue
		}
		for part in strings.split(value, "|", context.temp_allocator) {
			label := strings.trim_space(part)
			if label != "" do append(list, strings.clone(label))
		}
	}
}

// Empties the lists
InspectorPrefs_Clear :: proc(p: ^InspectorPrefs) {
	for kind in NodeKind {
		for l in p.pinned[kind] do delete(l)
		for c in p.collapsed[kind] do delete(c)
		clear(&p.pinned[kind])
		clear(&p.collapsed[kind])
	}
}

// Frees the lists
InspectorPrefs_Destroy :: proc(p: ^InspectorPrefs) {
	InspectorPrefs_Clear(p)
	for kind in NodeKind {
		delete(p.pinned[kind])
		delete(p.collapsed[kind])
	}
	p^ = {}
}

// Reads the project's `.editor/inspector.ini` (missing: nothing pinned or collapsed)
InspectorPrefs_Load :: proc(state: ^State) {
	InspectorPrefs_Clear(&state.inspectorPrefs)
	if state.project.rootPath == "" do return
	path, _ := filepath.join({state.project.rootPath, INSPECTOR_PREFS_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	InspectorPrefs_Parse(&state.inspectorPrefs, string(data))
}

/*
Writes `.editor/inspector.ini` (only for a project folder on disk).

Returns:
- "" or what went wrong
*/
InspectorPrefs_Save :: proc(state: ^State) -> string {
	root := state.project.rootPath
	if root == "" || !os.exists(root) do return ""
	path, _ := filepath.join({root, INSPECTOR_PREFS_FILE}, context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(path))
	text := InspectorPrefs_Text(&state.inspectorPrefs)
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil do return fmt.tprintf("Couldn't write %s: %v", path, err)
	return ""
}

/*
The pins' and sections' messages.

Returns:
- Whether `m` was one
*/
InspectorPrefs_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Inspector_Pin_Toggled:
		toggleIn(&state.inspectorPrefs.pinned[v.kind], v.label)
	case Inspector_Section_Toggled:
		toggleIn(&state.inspectorPrefs.collapsed[v.kind], v.section)
	case:
		return false
	}
	if problem := InspectorPrefs_Save(state); problem != "" do logLine(state, .Warning, strings.clone(problem))
	return true
}

/*
A section's header in the inspector: a chevron and its title; a click collapses or opens it for
nodes of that type (key `inspector-section-<key>`).
*/
inspectorSectionHeader :: proc(ctx: ^skald.Ctx(Msg), kind: NodeKind, key, title: string, collapsed: bool) -> skald.View {
	th := ctx.theme
	tk := uiTokens(ctx)
	label := fmt.tprintf("%s  %s", collapsed ? ICON_CHEVRON_RIGHT : ICON_CHEVRON_DOWN, title)
	button := skald.button(ctx, label, Msg(Inspector_Section_Toggled{kind = kind, section = key}),
		id = skald.hash_id(fmt.tprintf("inspector-section-%s", key)), bg = {}, fg = th.color.fg,
		padding = {0, tk.xxs}, font_size = th.font.size_sm, text_align = .Start)
	return skald.tooltip(ctx, button, collapsed ? "Show this section (remembered for this node type)" : "Hide this section (remembered for this node type)",
		id = skald.hash_id(fmt.tprintf("inspector-section-tip-%s", key)))
}

/*
Called by `inspectorRow` while the one-node inspector builds: the label with its pin (shown on
hover, always when pinned), and the row kept for the Pinned section when it's pinned.

Inputs:
- label: The row's label text
- labelView: Its label view
- control: Its control

Returns:
- The row, or `pinnedPlaceholder` when it went to the Pinned section; ok false when pins aren't
  being collected (another inspector), and the caller lays the row out itself
*/
inspectorPinnedRow :: proc(ctx: ^skald.Ctx(Msg), label: string, labelView, control: skald.View) -> (row: skald.View, ok: bool) {
	p := &inspectorPins
	if !p.active || label == "" do return {}, false
	th := ctx.theme
	tk := uiTokens(ctx)
	index := -1
	for l, i in p.labels do if l == label do index = i
	rowId := skald.hash_id(fmt.tprintf("inspector-row-%s", label))
	hovered := false
	if st, drawn := ctx.widgets.states[rowId]; drawn && st.last_drawn_frame + 1 >= ctx.widgets.frame {
		hovered = pointIn(st.last_rect, ctx.input.mouse_pos) && !Overlay_PopupOpen(ctx)
	}
	pin: skald.View = skald.spacer(0)
	if index >= 0 || hovered {
		button := skald.button(ctx, ICON_THUMBTACK, Msg(Inspector_Pin_Toggled{kind = p.kind, label = label}),
			id = skald.hash_id(fmt.tprintf("inspector-pin-%s", label)), bg = {}, fg = index >= 0 ? th.color.primary : th.color.fg_muted,
			padding = {tk.xxs, 0}, font_size = th.font.size_xs)
		pin = skald.tooltip(ctx, button, index >= 0 ? "Unpin (for every node of this type)" : "Pin to the top (for every node of this type)",
			id = skald.hash_id(fmt.tprintf("inspector-pin-tip-%s", label)))
	}
	composed := skald.zone(ctx, inspectorLabelled(ctx, skald.row(labelView, skald.flex(1, skald.spacer(0)), pin, cross_align = .Center), control), rowId)
	if index >= 0 {
		p.rows[index] = composed
		p.filled[index] = true
		return pinnedPlaceholder(), true
	}
	return composed, true
}

// Drops the places pinned rows left (`pinnedPlaceholder`)
Inspector_DropPlaceholders :: proc(rows: []skald.View) -> []skald.View {
	kept := make([dynamic]skald.View, 0, len(rows), context.temp_allocator)
	for v in rows {
		if spacer, isSpacer := v.(skald.View_Spacer); isSpacer && spacer.size == 0 && math.sign_bit(spacer.size) do continue
		append(&kept, v)
	}
	return kept[:]
}
