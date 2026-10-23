package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
More than one script on a node, and node types from game code (the engine's script.odin and
custom_nodes.odin).

**More scripts:** a node's first script is `NodeDef.script`; the inspector's **Add script**
(`Node_Script_Added`) puts others after it in `NodeDef.moreScripts` (one of each), each with its
own fields (`NodeScriptTarget`), its Open button (`Node_Script_Open`) and its × (`Node_Script_Removed`).
The game runs their hooks in order: the first script's, then the others'. Removing the first
script promotes the next one.

**Node types:** a struct of game code that embeds a built-in node type, registered with
`e.NodeType_Register(Player, .Sprite, {...})`, is a node kind of its own: the scripts' build lists
it (`ScriptCatalog.nodeTypes`), Add Node offers it under "Your node types" (`AddNode_Entries`),
and the node is a `NodeDef` of its base kind with `customKind` set, so the viewport and the
inspector treat it as its base (a Sprite's image, ...). Its exported fields are its own
inspector section (`NodeCustomTarget`). Scene files: `<node kind="Player" baseKind="Sprite">`
with `<prop>` children.

Widget keys for UI tests: `inspector-add-script`, `inspector-more-script-<i>-open`,
`inspector-more-script-<i>-remove`, `add-node-<Type>` for node types.
*/

// One of the node's more scripts' fields (`NodeDef.moreScripts`, by index)
NodeScriptTarget :: distinct int
// The node's own fields, as a node type of game code (`NodeDef.customProps`)
NodeCustomTarget :: struct {}

// Another script for the selected node (its name: the message's string lives for the frame)
Node_Script_Added :: distinct string
// Removes one of the selected node's more scripts, by index
Node_Script_Removed :: distinct int
// Opens a script or node type of the selected node in the code editor, by name
Node_Script_Open :: distinct string

// An Add Node choice: a built-in kind, or a node type of the project's code
AddNodeEntry :: struct {
	kind: NodeKind,
	// The node type's name ("" for the built-in kind)
	custom: string,
	// Its description (the engine's for built-in kinds)
	description: string,
}

/*
Add Node's choices for a search: the built-in kinds (`AddNode_Kinds`), then the project's node
types from the last build, whose name, base kind or "node type" matches.

Returns:
- The entries in the order the dialog lists them (temp allocated)
*/
AddNode_Entries :: proc(search: string, catalog: ^ScriptCatalog) -> []AddNodeEntry {
	entries := make([dynamic]AddNodeEntry, context.temp_allocator)
	for kind in AddNode_Kinds(search) do append(&entries, AddNodeEntry{kind = kind, description = e.SCENE_NODE_KINDS[kind].description})
	categoryMatches := matchesSearch(ADD_NODE_TYPES_HEADER, search)
	for &t in catalog.nodeTypes {
		if !categoryMatches && !matchesSearch(t.name, search) && !matchesSearch(fmt.tprint(t.base), search) do continue
		append(&entries, AddNodeEntry{kind = t.base, custom = t.name, description = fmt.tprintf("Your node type: a %v with its own code (%s)", t.base, t.file)})
	}
	return entries[:]
}

// The Add Node dialog's header over the project's node types
ADD_NODE_TYPES_HEADER :: "Your node types"

/*
The node types the catalog knows built on a kind (the inspector's choices for a node of it).

Returns:
- Their names (temp allocated)
*/
NodeTypes_On :: proc(catalog: ^ScriptCatalog, kind: NodeKind) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for t in catalog.nodeTypes do if t.base == kind do append(&names, t.name)
	return names[:]
}

/*
Applies the messages of this file to the selected node.

Returns:
- Whether the message was one of them
*/
NodeScripts_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Node_Script_Added:
		node := selectedNode(state)
		name := string(v)
		if node == nil || name == "" || name == TEXTURE_NONE do break
		if !NodeDef_AddScript(node, name) {
			logLine(state, .Warning, fmt.aprintf("%s already has %s", node.name, name))
			break
		}
		logLine(state, .Info, fmt.aprintf("Attached %s to %s", name, node.name))
	case Node_Script_Removed:
		node := selectedNode(state)
		i := int(v)
		if node == nil || i < 0 || i >= len(node.moreScripts) do break
		logLine(state, .Info, fmt.aprintf("Removed %s from %s", node.moreScripts[i].name, node.name))
		delete(node.moreScripts[i].name)
		Props_Destroy(&node.moreScripts[i].props)
		ordered_remove(&node.moreScripts, i)
	case Node_Script_Open:
		path, line := Script_Location(state, string(v))
		return Script_Open(state, path, line), true
	case:
		return {}, false
	}
	return {}, true
}

// One of the codes a node runs, with its field values (NodeDef_Codes)
NodeCode :: struct {
	// From the last build (nil before one, or when it's gone)
	desc: ^ScriptDesc,
	props: []ScriptPropDef,
}

/*
What a node runs, in the engine's order (`e.Node_Scripts`): its node type, its first script (a
Component instance's: its root's), its more scripts. A property "script.x" is the first of these
with a field x.

Returns:
- The list (temp allocated)
*/
NodeDef_Codes :: proc(s: ^State, node: ^NodeDef) -> []NodeCode {
	codes := make([dynamic]NodeCode, context.temp_allocator)
	if node.customKind != "" do append(&codes, NodeCode{ScriptCatalog_FindNodeType(&s.scripts, node.customKind), node.customProps[:]})
	if script := NodeDef_Script(&s.project, node); script != "" do append(&codes, NodeCode{ScriptCatalog_Find(&s.scripts, script), node.props[:]})
	for extra in node.moreScripts do append(&codes, NodeCode{ScriptCatalog_Find(&s.scripts, extra.name), extra.props[:]})
	return codes[:]
}

// Whether a node runs a script or node type of that name (first, more scripts, its own type)
NodeDef_Runs :: proc(node: ^NodeDef, name: string) -> bool {
	if name == "" do return false
	if node.script == name || node.customKind == name do return true
	for extra in node.moreScripts do if extra.name == name do return true
	return false
}

/*
Attaches another script to a node: its first script when it has none, else one of its more
scripts. A node has each script once.

Returns:
- false when the node already has it
*/
NodeDef_AddScript :: proc(node: ^NodeDef, name: string) -> bool {
	if node.script == name do return false
	for extra in node.moreScripts do if extra.name == name do return false
	if node.script == "" {
		delete(node.script)
		node.script = strings.clone(name)
		return true
	}
	append(&node.moreScripts, NodeScriptDef{name = strings.clone(name)})
	return true
}

/*
Removes a node's first script, its values with it. The next of its more scripts, if any,
becomes the first (scene files have no gap to keep).
*/
NodeDef_RemoveFirstScript :: proc(node: ^NodeDef) {
	delete(node.script)
	node.script = ""
	for prop in node.props { delete(prop.name); delete(prop.value) }
	clear(&node.props)
	if len(node.moreScripts) == 0 do return
	next := node.moreScripts[0]
	ordered_remove(&node.moreScripts, 0)
	node.script = next.name
	delete(node.props)
	node.props = next.props
}

/*
The inspector's rows for a node's more scripts: each with its fields, Open and remove, then the
Add script choice (scripts the node doesn't have yet).
*/
moreScriptsRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	for &extra, i in node.moreScripts {
		// The buttons follow the name, not the row's far end: a row in the inspector's scroll isn't
		// width-limited, and a flexible gap pushed them under its scrollbar in a narrow inspector
		append(&rows, skald.row(
			skald.text(fmt.tprintf("%s  %s", ICON_CODE, extra.name), th.color.fg, th.font.size_sm, max_width = inspectorRowWidth(controlWidth) - 60),
			smallButton(ctx, fmt.tprintf("inspector-more-script-%d-open", i), ICON_FILE_CODE, "Open the script in your code editor", Msg(Node_Script_Open(extra.name))),
			smallButton(ctx, fmt.tprintf("inspector-more-script-%d-remove", i), ICON_XMARK, "Remove this script from the node", Msg(Node_Script_Removed(i))),
			spacing = th.spacing.xs,
			cross_align = .Center,
		))
		append(&rows, ..fieldRows(ctx, s, extra.name, extra.props[:], ScriptCatalog_Find(&s.scripts, extra.name), fmt.tprintf("%d-%d", key, i), NodeScriptTarget(i), controlWidth, numberWidth))
	}
	// Scripts it could have too
	if node.script == "" do return rows[:]
	names := make([dynamic]string, context.temp_allocator)
	append(&names, ADD_SCRIPT_PROMPT)
	for desc in s.scripts.scripts {
		if desc.name == node.script do continue
		taken := false
		for extra in node.moreScripts do if extra.name == desc.name do taken = true
		if !taken do append(&names, desc.name)
	}
	if len(names) > 1 {
		append(&rows, inspectorRow(ctx, "Add script", skald.select(ctx, ADD_SCRIPT_PROMPT, names[:],
			proc(v: string) -> Msg { return Node_Script_Added(v == ADD_SCRIPT_PROMPT ? "" : v) },
			id = skald.hash_id(fmt.tprintf("inspector-add-script-%d", key)), width = controlWidth)))
	}
	return rows[:]
}

// The Add script choice's first entry
ADD_SCRIPT_PROMPT :: "Another script..."

/*
The inspector's section for a node of a node type from game code: what it is, Open, and its
exported fields from the last build.
*/
nodeTypeRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	if node.customKind == "" do return rows[:]
	desc := ScriptCatalog_FindNodeType(&s.scripts, node.customKind)
	append(&rows, skald.row(
		skald.text(fmt.tprintf("%s  %s", ICON_CODE, node.customKind), th.color.fg, th.font.size_sm),
		skald.flex(1, skald.spacer(0)),
		smallButton(ctx, "inspector-node-type-open", ICON_FILE_CODE, "Open the node type's code in your code editor", Msg(Node_Script_Open(node.customKind))),
		spacing = th.spacing.xs,
		cross_align = .Center,
	))
	append(&rows, skald.text(fmt.tprintf("A node type of your code, built on %v: it has a %v's settings above and its own code and fields.", node.kind, node.kind), th.color.fg_muted, th.font.size_xs, max_width = controlWidth + 100))
	if desc != nil && desc.base != node.kind {
		append(&rows, skald.text(fmt.tprintf("Its code now embeds a %v, not a %v: the game builds it as a %v.", desc.base, node.kind, node.kind), th.color.warning, th.font.size_xs, max_width = controlWidth + 100))
	}
	append(&rows, ..fieldRows(ctx, s, node.customKind, node.customProps[:], desc, fmt.tprintf("%d-type", key), NodeCustomTarget{}, controlWidth, numberWidth))
	return rows[:]
}

// A script's or node type's field rows: its fields once built, else its stored values (read only)
@(private="file")
fieldRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, name: string, props: []ScriptPropDef, desc: ^ScriptDesc, key: string, target: PropTarget, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	if desc == nil {
		message := s.scripts.status == .Building ? "Building..." : fmt.tprintf("Build the scripts%s to edit %s's fields.", keyParen(s, .Build_Scripts), name)
		append(&rows, skald.text(message, th.color.fg_muted, th.font.size_xs, max_width = 260))
		for prop in props do append(&rows, inspectorRow(ctx, prop.name, skald.text(prop.value, th.color.fg_muted, th.font.size_sm)))
		return rows[:]
	}
	for &field in desc.fields {
		append(&rows, inspectorRow(ctx, field.name, FieldControl(ctx, s, props, &field, key, target, controlWidth, numberWidth), scriptFieldTip(&field)))
	}
	return rows[:]
}

@(private="file")
smallButton :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg) -> skald.View {
	th := ctx.theme
	button := skald.button(ctx, icon, msg, id = skald.hash_id(key),
		bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
}
