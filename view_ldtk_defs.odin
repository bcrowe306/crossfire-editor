package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
The definitions editors in the Level mode's bottom tabs (phase 3 of TODO.md's "LDtk level
editor"), LDtk's definition panels laid out as the tabs' rows: **Layers** (EditLayerDefs: the
layer's settings, its IntGrid values and groups, its tileset, an auto-layer's source, an
Entities layer's tags), **Entities** (EditEntityDefs: the type's settings and its fields:
FieldDefsForm), **Enums** (EditEnumDefs: values, icons, external enum files), **Tilesets**
(EditTilesetDefs: image, grid, tags, the tile data picked on the tileset), and the **Level** tab's
level fields (EditLevelFieldDefs, which LDtk opens from its level panel). Every control sends an
`LDtk_Edit` (ldtk_defs.odin): one undo step, in memory until Save.

The tabs' lists (layers, entity types, enums, tilesets) are their sidebars (view_list_tab.odin), their
buttons on the toolbar row (`listTools`: Add a layer by type, an entity preset, a tileset of an
image; Duplicate, Delete, Up, Down); a sub-list (an entity type's fields, IntGrid values) has its
choice and buttons in the rows (`listButtons`). A tileset picker (`tilesetPicker`) picks
tile rectangles (an entity's tile, an enum value's icon, an IntGrid value's tile, a Tile field's
default) and tags tiles.

Widget keys: the lists' buttons `ldtk-<list>-add[-<what>]`, `-duplicate`, `-delete`, `-up`,
`-down` (`<list>`: layers, entities, fields, level-fields, enums, tilesets, intgrid, groups); a
member's control `ldtk-<kind>-<member>` (`ldtk-layer-gridSize`, `ldtk-entity-hollow`,
`ldtk-field-canBeNull`, `ldtk-enum-iconTilesetUid`, `ldtk-tileset-spacing`; a field's choice
`ldtk-item-Fields`, a level field's `ldtk-item-Level_Fields`, a tileset's `ldtk-item-Tilesets`),
IntGrid values `ldtk-intgrid-name-<v>`, `-color-<v>`, `-group-<v>`, `-up-<v>`, `-down-<v>`,
`-remove-<v>`, `-tile-<v>`, groups `ldtk-group-name-<uid>`, `-color-<uid>`, `-remove-<uid>`,
`-up-<uid>`, `-down-<uid>`; enum values `ldtk-enum-value-<i>`, `-color-<i>`, `-up-<i>`,
`-down-<i>`, `-remove-<i>`, `-icon-<i>`; external enums `ldtk-enums-import`,
`ldtk-enums-sync-<i>`, `ldtk-enums-unlink-<i>`; tile pickers `ldtk-picker-<what>` (the tileset's
own `ldtk-picker-tileset`), the tile data's mode `ldtk-tileset-mode`, a tile's data
`ldtk-tileset-data`.
*/

// The text of a list's kind in keys
@(private="file")
kindKey :: proc(kind: LDtkDefKind) -> string {
	switch kind {
	case .Layer: return "layer"
	case .Entity: return "entity"
	case .Field: return "field"
	case .Enum: return "enum"
	case .Tileset: return "tileset"
	}
	return ""
}

// A member edit of a definition (`Def_Set`; a field's uid in `field`)
@(private="file")
defEdit :: proc(c: ^LDtkTabCtx, kind: LDtkDefKind, uid: int, key: string) -> LDtk_Edit {
	e := tabBase(c, .Def_Set)
	e.kind, e.key = kind, key
	if kind == .Field do e.field = uid
	else do e.def = uid
	return e
}

// A small button (a list's actions)
@(private)
smallButton :: proc(c: ^LDtkTabCtx, key, label: string, msg: Msg, disabled := false) -> skald.View {
	tk := uiTokens(c.ctx)
	th := c.ctx.theme
	return skald.button(c.ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
		padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm, disabled = disabled)
}

// A row of buttons (wrapped in a narrow panel)
@(private)
buttonRow :: proc(c: ^LDtkTabCtx, buttons: ..skald.View) {
	th := c.ctx.theme
	views := make([]skald.View, len(buttons), context.temp_allocator)
	copy(views, buttons)
	append(c.rows, skald.wrap_row(..views, spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = c.rowWidth))
}

/*
The tab's main list's Duplicate, Delete, Up and Down on its toolbar row (`prefix`: the keys' list,
`what`: its items' name in the tooltips), after its Add buttons.
*/
@(private)
listTools :: proc(c: ^LDtkTabCtx, prefix, what: string, edit: LDtk_Edit, at, count: int) {
	dup, del, up, down := edit, edit, edit, edit
	dup.op, del.op, up.op, down.op = .Def_Duplicated, .Def_Removed, .Def_Moved, .Def_Moved
	up.number, down.number = -1, 1
	tabTool(c, fmt.tprintf("ldtk-%s-duplicate", prefix), ICON_COPY, fmt.tprintf("Duplicate the %s", what), Msg(dup))
	tabTool(c, fmt.tprintf("ldtk-%s-delete", prefix), ICON_TRASH, fmt.tprintf("Delete the %s", what), Msg(del))
	tabTool(c, fmt.tprintf("ldtk-%s-up", prefix), ICON_ARROW_UP, fmt.tprintf("Move the %s up", what), Msg(up), disabled = at <= 0)
	tabTool(c, fmt.tprintf("ldtk-%s-down", prefix), ICON_ARROW_DOWN, fmt.tprintf("Move the %s down", what), Msg(down), disabled = at >= count - 1)
}

// A list's Duplicate, Delete, Up and Down in a row of the content (a sub-list: fields)
@(private="file")
listButtons :: proc(c: ^LDtkTabCtx, prefix: string, edit: LDtk_Edit, at, count: int, extra: ..skald.View) {
	dup, del, up, down := edit, edit, edit, edit
	dup.op, del.op, up.op, down.op = .Def_Duplicated, .Def_Removed, .Def_Moved, .Def_Moved
	up.number, down.number = -1, 1
	buttons := make([dynamic]skald.View, context.temp_allocator)
	append(&buttons, ..extra)
	append(&buttons,
		smallButton(c, fmt.tprintf("ldtk-%s-duplicate", prefix), fmt.tprintf("%s  Duplicate", ICON_COPY), Msg(dup)),
		smallButton(c, fmt.tprintf("ldtk-%s-delete", prefix), fmt.tprintf("%s  Delete", ICON_TRASH), Msg(del)),
		smallButton(c, fmt.tprintf("ldtk-%s-up", prefix), ICON_ARROW_UP, Msg(up), disabled = at <= 0),
		smallButton(c, fmt.tprintf("ldtk-%s-down", prefix), ICON_ARROW_DOWN, Msg(down), disabled = at >= count - 1),
	)
	buttonRow(c, ..buttons[:])
}

// A member's text field (applied as it's typed whenever valid)
@(private="file")
memberText :: proc(c: ^LDtkTabCtx, label, tip: string, kind: LDtkDefKind, uid: int, key, value: string) {
	tabRow(c, label, tabTextField(c, fmt.tprintf("ldtk-%s-%s", kindKey(kind), key), value, defEdit(c, kind, uid, key)), tip)
}

// A member's number field
@(private="file")
memberNumber :: proc(c: ^LDtkTabCtx, label, tip: string, kind: LDtkDefKind, uid: int, key: string, value, step: f64, decimals: int, lo, hi: f64) {
	tabNumberRow(c, label, fmt.tprintf("ldtk-%s-%s", kindKey(kind), key), tip, defEdit(c, kind, uid, key), value, step, decimals, lo, hi)
}

// A member's checkbox
@(private="file")
memberFlag :: proc(c: ^LDtkTabCtx, label, tip: string, kind: LDtkDefKind, uid: int, key: string, value: bool) {
	tabFlagRow(c, label, fmt.tprintf("ldtk-%s-%s", kindKey(kind), key), tip, defEdit(c, kind, uid, key), value)
}

// A member's choice (`values` are what's sent; "" null)
@(private="file")
memberChoice :: proc(c: ^LDtkTabCtx, label, tip: string, kind: LDtkDefKind, uid: int, key, shown: string, labels, values: []string) {
	tabRow(c, label, tabChoiceField(c, fmt.tprintf("ldtk-%s-%s", kindKey(kind), key), shown, labels, values, defEdit(c, kind, uid, key)), tip)
}

// A member's color (#RRGGBB; nullable ones empty for none)
@(private="file")
memberColor :: proc(c: ^LDtkTabCtx, label, tip: string, kind: LDtkDefKind, uid: int, key, value: string) {
	tabRow(c, label, tabColorField(c, fmt.tprintf("ldtk-%s-%s", kindKey(kind), key), value, defEdit(c, kind, uid, key)), tip)
}

// Tags as a text ("a, b")
@(private="file")
tagsText :: proc(json: ^JsonDoc, node: int) -> string {
	tags := make([dynamic]string, context.temp_allocator)
	for t in Json_Items(json, node) do append(&tags, Json_String(json, t))
	return strings.join(tags[:], ", ", context.temp_allocator)
}

// A nullable uid as the choices' value ("" none)
@(private="file")
uidText :: proc(json: ^JsonDoc, node: int) -> string {
	if Json_Kind(json, node) != .Number do return ""
	return fmt.tprint(Json_Int(json, node))
}

// A JSON number as a field's text ("" for null)
@(private="file")
numberText :: proc(json: ^JsonDoc, node: int) -> string {
	if Json_Kind(json, node) != .Number do return ""
	return Json_Text(json, node)
}

/*
The choices of a definition list: labels and uid values, with "(none)" first when `none` (the
list's own name: "No tileset").
*/
@(private="file")
defChoices :: proc(c: ^LDtkTabCtx, list: int, none := "", filter: proc(json: ^JsonDoc, node: int) -> bool = nil) -> (labels, values: []string) {
	ls := make([dynamic]string, context.temp_allocator)
	vs := make([dynamic]string, context.temp_allocator)
	if none != "" {
		append(&ls, none)
		append(&vs, "")
	}
	for d in Json_Items(c.main, list) {
		if filter != nil && !filter(c.main, d) do continue
		append(&ls, Json_String(c.main, Json_Get(c.main, d, "identifier")))
		append(&vs, fmt.tprint(Json_Int(c.main, Json_Get(c.main, d, "uid"))))
	}
	return ls[:], vs[:]
}

// The label of a choice's value (the value itself when it's none of them)
@(private)
labelOf :: proc(labels, values: []string, value: string) -> string {
	for v, i in values do if v == value do return labels[i]
	return value
}

/*
LevelMode_SelectMade picks what a definition edit made (LDtk selects a new or copied definition):
the new layer (on top), entity type, field, enum or tileset, a copy (after its original); a level's
copy.
*/
LevelMode_SelectMade :: proc(s: ^State, edit: LDtk_Edit) {
	// A level's copy is selected (WorldPanel's Duplicate: `editor.selectLevel(copy)`)
	if edit.op == .Level_Duplicated && edit.text != "" {
		doc := LDtkDoc_Get(s.project.rootPath, edit.file)
		if doc == nil || doc.problem != "" do return
		if at := LDtkDoc_FindLevel(doc, edit.text); at >= 0 {
			id, _ := LDtkDoc_LevelNames(doc, at)
			levelSelect(s, edit.file, strings.clone(id, context.temp_allocator))
		}
		return
	}
	if edit.op != .Def_Added && edit.op != .Def_Duplicated && edit.op != .Enum_Added do return
	doc := LDtkDoc_Get(s.project.rootPath, edit.file)
	if doc == nil || doc.problem != "" do return
	main := LDtkDoc_Main(doc)
	uidAt :: proc(main: ^JsonDoc, list, index: int) -> int {
		n := Json_Count(main, list)
		if n == 0 do return -1
		return Json_Int(main, Json_Get(main, Json_At(main, list, index < 0 ? n - 1 : index), "uid"), -1)
	}
	after :: proc(main: ^JsonDoc, list, uid: int) -> int {
		items := Json_Items(main, list)
		for d, i in items do if Json_Int(main, Json_Get(main, d, "uid")) == uid && i + 1 < len(items) do return Json_Int(main, Json_Get(main, items[i + 1], "uid"))
		return -1
	}
	if edit.op == .Enum_Added {
		s.level.enumDef = uidAt(main, LDtkDoc_Defs(doc, "enums"), -1)
		return
	}
	dup := edit.op == .Def_Duplicated
	switch edit.kind {
	case .Layer:
		list := LDtkDoc_Defs(doc, "layers")
		s.level.layerDef = dup ? after(main, list, edit.def) : uidAt(main, list, 0)
	case .Entity:
		list := LDtkDoc_Defs(doc, "entities")
		s.level.entityDef = dup ? after(main, list, edit.def) : uidAt(main, list, -1)
		s.level.fieldDef = -1
	case .Field:
		owner, _ := LDtkDoc_FieldDef(doc, edit.field)
		list := -1
		level := false
		if dup {
			list = owner == LDtkDoc_Defs(doc, "levelFields") ? owner : Json_Get(main, owner, "fieldDefs")
			level = owner == LDtkDoc_Defs(doc, "levelFields")
		} else if edit.def < 0 {
			list = LDtkDoc_Defs(doc, "levelFields")
			level = true
		} else {
			list = Json_Get(main, LDtkDoc_DefByUid(doc, "entities", edit.def), "fieldDefs")
		}
		uid := dup ? after(main, list, edit.field) : uidAt(main, list, -1)
		if level do s.level.levelField = uid
		else do s.level.fieldDef = uid
	case .Enum:
		list := LDtkDoc_Defs(doc, "enums")
		s.level.enumDef = dup ? after(main, list, edit.def) : uidAt(main, list, -1)
	case .Tileset:
		list := LDtkDoc_Defs(doc, "tilesets")
		s.level.tilesetDef = dup ? after(main, list, edit.def) : uidAt(main, list, -1)
	}
}

// --- Layers ----------------------------------------------------------------------------------

/*
The Layers tab's definitions (EditLayerDefs): the layer list's buttons, then the selected layer's
settings by its type.
*/
LDtkDefs_Layers :: proc(c: ^LDtkTabCtx) {
	main := c.main
	th := c.ctx.theme
	// The toolbar row: a new layer of each type, then the list's buttons
	add :: proc(c: ^LDtkTabCtx, type: string) {
		e := tabBase(c, .Def_Added)
		e.kind, e.text = .Layer, type
		tabTool(c, fmt.tprintf("ldtk-layers-add-%s", type), ICON_PLUS, fmt.tprintf("A new %s layer, on top", type), Msg(e), label = type)
	}
	add(c, "IntGrid")
	add(c, "Entities")
	add(c, "Tiles")
	add(c, "AutoLayer")
	c.list.empty = "No layers: + adds one."
	def := tabItemChoice(c, .Layers, LDtkDoc_Defs(c.doc, "layers"), c.s.level.layerDef)
	if def < 0 {
		tabNote(c, "This project has no layers: add one (the buttons above).")
		return
	}
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	type := Json_String(main, Json_Get(main, def, "type"))
	items := Json_Items(main, LDtkDoc_Defs(c.doc, "layers"))
	at, _ := slice.linear_search(items, def)
	e := tabBase(c, .Def_Removed)
	e.kind, e.def = .Layer, uid
	listTools(c, "layers", "layer", e, at, len(items))
	c.list.text = fmt.tprintf("%s: %d of %d, top first (changes apply to every level)", Json_String(main, Json_Get(main, def, "identifier")), at + 1, len(items))
	if Json_Int(main, Json_Get(main, def, "uid")) >= 0 && type == "IntGrid" {
		for d in items do if Json_Int(main, Json_Get(main, d, "autoSourceLayerDefUid"), -1) == uid {
			tabNote(c, fmt.tprintf("%s builds its tiles from this layer: deleting it leaves that auto-layer without a source.", Json_String(main, Json_Get(main, d, "identifier"))), true)
		}
	}

	// The settings every layer has (the old rows kept their keys)
	edit :: proc(c: ^LDtkTabCtx, op: LDtkEditOp, uid: int) -> LDtk_Edit { x := tabBase(c, op); x.def = uid; return x }
	tabRow(c, "Name", tabTextField(c, "ldtk-layer-name", Json_String(main, Json_Get(main, def, "identifier")), edit(c, .Layer_Name, uid)), "The layer's identifier: games and LDtkLevel nodes find it by name (scenes naming it follow a rename)")
	kind := type
	if Json_Count(main, Json_Get(main, def, "autoRuleGroups")) > 0 do kind = fmt.tprintf("%s with auto-layer rules", kind)
	tabRow(c, "Type", uiText(th, .Value, kind), "What the layer holds (LDtk's layers keep their type)")
	memberText(c, "Documentation", "A note about the layer, shown in LDtk's lists (empty: none)", .Layer, uid, "doc", Json_String(main, Json_Get(main, def, "doc")))
	memberColor(c, "List color", "The layer's color in LDtk's lists, #RRGGBB (empty: none)", .Layer, uid, "uiColor", Json_String(main, Json_Get(main, def, "uiColor")))
	if c.level >= 0 {
		file, array := LDtkDoc_LayerInstances(c.doc, c.level)
		json := LDtkDoc_Json(c.doc, file)
		for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == uid {
			tabFlagRow(c, fmt.tprintf("Shown in %s", c.s.level.level), "ldtk-layer-visible", "Whether this level shows the layer (LDtk's eye; the engine skips hidden layers)", edit(c, .Layer_Visible, uid), Json_Bool(json, Json_Get(json, li, "visible"), true))
		}
	}
	tabNumberRow(c, "Opacity", "ldtk-layer-opacity", "How opaque the layer draws, 0.1 to 1", edit(c, .Layer_Opacity, uid), Json_Float(main, Json_Get(main, def, "displayOpacity"), 1), 0.05, 2, 0.1, 1)
	memberNumber(c, "Inactive opacity", "How opaque LDtk draws it while another layer is selected, 0 to 1", .Layer, uid, "inactiveOpacity", Json_Float(main, Json_Get(main, def, "inactiveOpacity"), 1), 0.05, 2, 0, 1)
	grid := Json_Int(main, Json_Get(main, def, "gridSize"), 16)
	if why := LDtkOps_GridSizeLocked(c.doc, uid); why != "" {
		tabRow(c, "Grid size", uiText(th, .Value, fmt.tprintf("%d px", grid)), "The layer's cell size in pixels")
		tabNote(c, fmt.tprintf("%s.", why))
	} else {
		tabNumberRow(c, "Grid size", "ldtk-layer-grid", "The layer's cell size in pixels: every level's cells keep their place (those past the new size go), entities move with it", edit(c, .Layer_Grid_Size, uid), f64(grid), 1, 0, 1, LDTK_MAX_GRID_SIZE)
	}
	memberNumber(c, "Guide grid width", "A second grid LDtk draws over this one, in pixels (0: none)", .Layer, uid, "guideGridWid", Json_Float(main, Json_Get(main, def, "guideGridWid")), 1, 0, 0, LDTK_MAX_GRID_SIZE)
	memberNumber(c, "Guide grid height", "The guide grid's height in pixels (0: none)", .Layer, uid, "guideGridHei", Json_Float(main, Json_Get(main, def, "guideGridHei")), 1, 0, 0, LDTK_MAX_GRID_SIZE)
	memberNumber(c, "Offset X", "Where the layer is drawn, in pixels from the level's left (every level)", .Layer, uid, "pxOffsetX", Json_Float(main, Json_Get(main, def, "pxOffsetX")), 1, 0, -100000, 100000)
	memberNumber(c, "Offset Y", "In pixels from the level's top", .Layer, uid, "pxOffsetY", Json_Float(main, Json_Get(main, def, "pxOffsetY")), 1, 0, -100000, 100000)
	tabNumberRow(c, "Parallax X", "ldtk-layer-parallax-x", "How much slower (positive) or faster (negative) the layer scrolls sideways, -1 to 1 (Y follows while they're the same)", edit(c, .Layer_Parallax_X, uid), Json_Float(main, Json_Get(main, def, "parallaxFactorX")), 0.05, 2, -1, 1)
	scaling := Json_Bool(main, Json_Get(main, def, "parallaxScaling"), true)
	if scaling {
		tabRow(c, "Parallax Y", uiText(th, .Muted, fmt.tprintf("%g (as X: parallax scaling)", Json_Float(main, Json_Get(main, def, "parallaxFactorY")))), "With parallax scaling, Y is X's")
	} else {
		memberNumber(c, "Parallax Y", "The same up and down, -1 to 1", .Layer, uid, "parallaxFactorY", Json_Float(main, Json_Get(main, def, "parallaxFactorY")), 0.05, 2, -1, 1)
	}
	tabFlagRow(c, "Parallax scaling", "ldtk-layer-parallax-scaling", "Whether a parallax layer also scales with its factor (Y is then X's)", edit(c, .Layer_Parallax_Scaling, uid), scaling)
	memberFlag(c, "Hidden in list", "Whether LDtk's layer list leaves it out", .Layer, uid, "hideInList", Json_Bool(main, Json_Get(main, def, "hideInList")))
	memberFlag(c, "Hide fields", "Whether LDtk hides its entities' fields while another layer is selected", .Layer, uid, "hideFieldsWhenInactive", Json_Bool(main, Json_Get(main, def, "hideFieldsWhenInactive")))
	memberFlag(c, "Pick inactive", "Whether LDtk picks its content while another layer is selected", .Layer, uid, "canSelectWhenInactive", Json_Bool(main, Json_Get(main, def, "canSelectWhenInactive"), true))
	memberFlag(c, "In the world view", "Whether LDtk's world view draws it", .Layer, uid, "renderInWorldView", Json_Bool(main, Json_Get(main, def, "renderInWorldView"), true))
	memberFlag(c, "Async render", "LDtk's asynchronous rendering for big layers", .Layer, uid, "useAsyncRender", Json_Bool(main, Json_Get(main, def, "useAsyncRender")))
	memberText(c, "Filter tags", "Tags LDtk's layer list filters by, separated by commas", .Layer, uid, "uiFilterTags", tagsText(main, Json_Get(main, def, "uiFilterTags")))

	// What the type has
	tilesets := LDtkDoc_Defs(c.doc, "tilesets")
	tsLabels, tsValues := defChoices(c, tilesets, "No tileset")
	switch type {
	case "IntGrid":
		tabHeading(c, "Auto-layer")
		tsShown := labelOf(tsLabels, tsValues, uidText(main, Json_Get(main, def, "tilesetDefUid")))
		memberChoice(c, "Rules' tileset", "The tileset its auto-layer rules draw with (none: no rules; LDtk drops them on save)", .Layer, uid, "tilesetDefUid", tsShown, tsLabels, tsValues)
		autoSettings(c, def, uid)
		defsIntGridValues(c, def)
	case "AutoLayer":
		tabHeading(c, "Auto-layer")
		srcLabels, srcValues := defChoices(c, LDtkDoc_Defs(c.doc, "layers"), "No source", proc(json: ^JsonDoc, d: int) -> bool { return Json_String(json, Json_Get(json, d, "type")) == "IntGrid" })
		memberChoice(c, "Source layer", "The IntGrid layer whose cells its rules read (it takes that layer's grid)", .Layer, uid, "autoSourceLayerDefUid", labelOf(srcLabels, srcValues, uidText(main, Json_Get(main, def, "autoSourceLayerDefUid"))), srcLabels, srcValues)
		memberChoice(c, "Tileset", "The tileset its rules draw with", .Layer, uid, "tilesetDefUid", labelOf(tsLabels, tsValues, uidText(main, Json_Get(main, def, "tilesetDefUid"))), tsLabels, tsValues)
		if Json_Kind(main, Json_Get(main, def, "autoSourceLayerDefUid")) != .Number || Json_Kind(main, Json_Get(main, def, "tilesetDefUid")) != .Number do tabNote(c, "An auto-layer needs a source layer and a tileset before its rules draw anything.", true)
		autoSettings(c, def, uid)
	case "Tiles":
		tabHeading(c, "Tiles")
		memberChoice(c, "Tileset", "The tileset it paints with (it takes the tileset's grid)", .Layer, uid, "tilesetDefUid", labelOf(tsLabels, tsValues, uidText(main, Json_Get(main, def, "tilesetDefUid"))), tsLabels, tsValues)
		if ts := LDtkDoc_DefByUid(c.doc, "tilesets", Json_Int(main, Json_Get(main, def, "tilesetDefUid"), -1)); ts >= 0 {
			tg := Json_Int(main, Json_Get(main, ts, "tileGridSize"), 16)
			if grid != tg && (tg < grid || tg % max(grid, 1) != 0) do tabNote(c, fmt.tprintf("The tileset's grid (%d px) differs from the layer's (%d px) and isn't a multiple of it: groups of tiles may land oddly.", tg, grid), true)
		}
		memberNumber(c, "Tile pivot X", "Where a tile sits in its cell across: 0 left, 1 right", .Layer, uid, "tilePivotX", Json_Float(main, Json_Get(main, def, "tilePivotX")), 0.5, 1, 0, 1)
		memberNumber(c, "Tile pivot Y", "Where it sits up and down: 0 top, 1 bottom", .Layer, uid, "tilePivotY", Json_Float(main, Json_Get(main, def, "tilePivotY")), 0.5, 1, 0, 1)
	case "Entities":
		tabHeading(c, "Entities")
		memberText(c, "Required tags", "Only entity types with one of these tags go in this layer (empty: any)", .Layer, uid, "requiredTags", tagsText(main, Json_Get(main, def, "requiredTags")))
		memberText(c, "Excluded tags", "Entity types with one of these tags don't go in this layer", .Layer, uid, "excludedTags", tagsText(main, Json_Get(main, def, "excludedTags")))
	}
	upDown := tabBase(c, .Layer_Move)
	upDown.def = uid
	tabNote(c, fmt.tprintf("%d of %d, top first: higher draws over lower (Up and Down above, or drag its row in the Layers sidebar).", at + 1, len(items)))
}

// An auto-layer's other settings: what removes its tiles, its biome field
@(private="file")
autoSettings :: proc(c: ^LDtkTabCtx, def, uid: int) {
	main := c.main
	killLabels, killValues := defChoices(c, LDtkDoc_Defs(c.doc, "layers"), "None", proc(json: ^JsonDoc, d: int) -> bool { return Json_String(json, Json_Get(json, d, "type")) == "Tiles" })
	memberChoice(c, "Tiles removed by", "A Tiles layer whose painted tiles remove the rules' tiles under them", .Layer, uid, "autoTilesKilledByOtherLayerUid",
		labelOf(killLabels, killValues, uidText(main, Json_Get(main, def, "autoTilesKilledByOtherLayerUid"))), killLabels, killValues)
	biomeLabels, biomeValues := defChoices(c, LDtkDoc_Defs(c.doc, "levelFields"), "No biome", proc(json: ^JsonDoc, d: int) -> bool { return strings.has_prefix(Json_String(json, Json_Get(json, d, "type")), "F_Enum(") })
	memberChoice(c, "Biome field", "A level field of an enum: rule groups can need its values (LDtk's biomes)", .Layer, uid, "biomeFieldUid",
		labelOf(biomeLabels, biomeValues, uidText(main, Json_Get(main, def, "biomeFieldUid"))), biomeLabels, biomeValues)
	tabNote(c, "Its rules are edited in the Auto-layer Rules tab.")
}

/*
An IntGrid layer's values by group (EditLayerDefs' grouped values): each value's name, color,
group, place, tile (from the icons' tileset), removal; groups' names, colors, order, removal; new
values and groups.
*/
@(private="file")
defsIntGridValues :: proc(c: ^LDtkTabCtx, def: int) {
	main := c.main
	th := c.ctx.theme
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	heading := "IntGrid values"
	tabHeading(c, heading)
	values := Json_Items(main, Json_Get(main, def, "intGridValues"))
	groups := Json_Items(main, Json_Get(main, def, "intGridValuesGroups"))
	// The icons' tileset: the one a value's tile uses (EditLayerDefs guesses it the same way)
	icons := -1
	for v in values do if t := Json_Get(main, v, "tile"); Json_Kind(main, t) == .Object {
		icons = Json_Int(main, Json_Get(main, t, "tilesetUid"))
		break
	}
	if icons < 0 do icons = c.s.level.tilesetDef
	if LDtkDoc_DefByUid(c.doc, "tilesets", icons) < 0 do icons = -1
	groupLabels := make([dynamic]string, context.temp_allocator)
	groupValues := make([dynamic]string, context.temp_allocator)
	append(&groupLabels, "No group")
	append(&groupValues, "0")
	for g in groups {
		name := Json_String(main, Json_Get(main, g, "identifier"))
		gid := Json_Int(main, Json_Get(main, g, "uid"))
		append(&groupLabels, name != "" ? name : fmt.tprintf("Group %d", gid))
		append(&groupValues, fmt.tprint(gid))
	}
	edit :: proc(c: ^LDtkTabCtx, op: LDtkEditOp, uid, index: int) -> LDtk_Edit { x := tabBase(c, op); x.def, x.index = uid, index; return x }
	addValue := edit(c, .IntGrid_Value_Added, uid, 0)
	addGroup := edit(c, .IntGrid_Group_Added, uid, 0)
	buttonRow(c, smallButton(c, "ldtk-intgrid-add", fmt.tprintf("%s  Value", ICON_PLUS), Msg(addValue)), smallButton(c, "ldtk-groups-add", fmt.tprintf("%s  Group", ICON_PLUS), Msg(addGroup)))
	if len(values) == 0 do tabNote(c, "No values yet.")
	// Groups: no group first, then each in order
	order := make([dynamic]int, context.temp_allocator)
	append(&order, 0)
	for g in groups do append(&order, Json_Int(main, Json_Get(main, g, "uid")))
	for gid, gi in order {
		inGroup := make([dynamic]int, context.temp_allocator)
		for v in values do if Json_Int(main, Json_Get(main, v, "groupUid")) == gid do append(&inGroup, v)
		if len(groups) > 0 {
			if gid == 0 {
				tabNote(c, "No group")
			} else {
				g := groups[gi - 1]
				e := edit(c, .IntGrid_Group_Set, uid, gid)
				e.key = "identifier"
				tabRow(c, fmt.tprintf("Group %d", gid), tabTextField(c, fmt.tprintf("ldtk-group-name-%d", gid), Json_String(main, Json_Get(main, g, "identifier")), e), "The group's name (empty: none): rules can match any of its values")
				e.key = "color"
				tabRow(c, "   Color", tabColorField(c, fmt.tprintf("ldtk-group-color-%d", gid), strings.to_upper(Json_String(main, Json_Get(main, g, "color")), context.temp_allocator), e), "The group's color, #RRGGBB (empty: none)")
				up, down := edit(c, .IntGrid_Group_Moved, uid, gid), edit(c, .IntGrid_Group_Moved, uid, gid)
				up.number, down.number = -1, 1
				buttonRow(c, smallButton(c, fmt.tprintf("ldtk-group-up-%d", gid), ICON_ARROW_UP, Msg(up), disabled = gi <= 1),
					smallButton(c, fmt.tprintf("ldtk-group-down-%d", gid), ICON_ARROW_DOWN, Msg(down), disabled = gi >= len(order) - 1),
					smallButton(c, fmt.tprintf("ldtk-group-remove-%d", gid), fmt.tprintf("%s  Remove group", ICON_TRASH), Msg(edit(c, .IntGrid_Group_Removed, uid, gid))))
			}
		}
		for v, vi in inGroup {
			value := Json_Int(main, Json_Get(main, v, "value"))
			e := edit(c, .IntGrid_Name, uid, value)
			tabRow(c, fmt.tprintf("Value %d", value), tabTextField(c, fmt.tprintf("ldtk-intgrid-name-%d", value), Json_String(main, Json_Get(main, v, "identifier")), e), "The value's name (empty: none): games and Area nodes made from it use it")
			e.op = .IntGrid_Color
			tabRow(c, "   Color", tabColorField(c, fmt.tprintf("ldtk-intgrid-color-%d", value), Json_String(main, Json_Get(main, v, "color")), e), "The value's color, #RRGGBB")
			if len(groups) > 0 {
				move := edit(c, .IntGrid_Value_Moved, uid, value)
				shown := labelOf(groupLabels[:], groupValues[:], fmt.tprint(gid))
				Move :: struct { edit: LDtk_Edit }
				pick := labeledSelect(c.ctx, shown, groupLabels[:], groupValues[:], Move{move}, proc(m: Move, v: string) -> Msg {
					e := m.edit
					n, _ := strconv.parse_int(v)
					e.number, e.number2 = f64(n), 1e9
					return e
				}, id = skald.hash_id(fmt.tprintf("ldtk-intgrid-group-%d", value)), width = c.controlWidth)
				tabRow(c, "   Group", pick, "The group it's in (it goes to the group's end)")
			}
			up, down := edit(c, .IntGrid_Value_Moved, uid, value), edit(c, .IntGrid_Value_Moved, uid, value)
			up.number, up.number2 = f64(gid), f64(vi - 1)
			down.number, down.number2 = f64(gid), f64(vi + 1)
			buttons := make([dynamic]skald.View, context.temp_allocator)
			append(&buttons,
				smallButton(c, fmt.tprintf("ldtk-intgrid-up-%d", value), ICON_ARROW_UP, Msg(up), disabled = vi == 0),
				smallButton(c, fmt.tprintf("ldtk-intgrid-down-%d", value), ICON_ARROW_DOWN, Msg(down), disabled = vi >= len(inGroup) - 1),
				smallButton(c, fmt.tprintf("ldtk-intgrid-remove-%d", value), fmt.tprintf("%s  Remove", ICON_TRASH), Msg(edit(c, .IntGrid_Value_Removed, uid, value))))
			if icons >= 0 {
				tile := edit(c, .IntGrid_Value_Tile, uid, value)
				tile.number = f64(icons)
				clear := tile
				append(&buttons, smallButton(c, fmt.tprintf("ldtk-intgrid-tile-clear-%d", value), "No tile", Msg(clear), disabled = Json_Kind(main, Json_Get(main, v, "tile")) != .Object))
			}
			buttonRow(c, ..buttons[:])
			if icons >= 0 {
				tile := edit(c, .IntGrid_Value_Tile, uid, value)
				tile.number = f64(icons)
				append(c.rows, tilesetPicker(c, fmt.tprintf("intgrid-%d", value), icons, rectOf(main, Json_Get(main, v, "tile")), tile, small = true))
			}
		}
	}
	tsLabels, tsValues := defChoices(c, LDtkDoc_Defs(c.doc, "tilesets"), "No icons")
	Icons :: struct { edit: LDtk_Edit }
	clearAll := edit(c, .IntGrid_Value_Tile, uid, -1)
	pick := labeledSelect(c.ctx, labelOf(tsLabels, tsValues, icons >= 0 ? fmt.tprint(icons) : ""), tsLabels, tsValues, Icons{clearAll}, proc(i: Icons, v: string) -> Msg {
		// Another icons tileset: the values' tiles go (EditLayerDefs), then it's picked
		n, ok := strconv.parse_int(v)
		if !ok do return i.edit
		return LDtk_Def_Picked{what = .Tileset, uid = n}
	}, id = skald.hash_id("ldtk-intgrid-icons"), width = c.controlWidth)
	tabRow(c, "Icons' tileset", pick, "The tileset the values' tiles come from (choosing none removes them)")
	_ = th
	// What scenes' LDtkLevel nodes make of the values (the old Collisions)
	ldtkIntGridKinds(c, def)
}

// A tile rectangle's {x, y, w, h} (nil: none)
@(private)
rectOf :: proc(json: ^JsonDoc, node: int) -> Maybe([4]int) {
	if Json_Kind(json, node) != .Object do return nil
	return [4]int{Json_Int(json, Json_Get(json, node, "x")), Json_Int(json, Json_Get(json, node, "y")), Json_Int(json, Json_Get(json, node, "w")), Json_Int(json, Json_Get(json, node, "h"))}
}

// --- Tile pickers ------------------------------------------------------------------------------

// A picker's drag (by its key): the first cell pressed, the button
@(private="file")
PickerDrag :: struct {
	dragging, right: bool,
	start: [2]int,
}

@(private="file", thread_local)
pickerDrags: map[string]PickerDrag

// Frees the pickers' state (tests, quitting)
LDtkDefs_Destroy :: proc() {
	for k in pickerDrags do delete(k)
	delete(pickerDrags)
	pickerDrags = nil
}

// What a tileset picker does with a selection
@(private)
PickerMode :: enum {
	// A tile rectangle: the edit with `text` "x,y,w,h"
	Rect,
	// Tiles tagged or untagged (the left button adds, the right removes): the edit with `ids`, `flag`
	Tags,
	// One tile: `LDtk_Def_Picked{.Data_Tile}`
	Tile,
}

/*
A tileset drawn for picking (LDtk's tile rect picker and tagger): its image fitted to the tab's
width (or `small`: at most 160 px wide), the selection outlined, tagged tiles colored; a drag
picks a rectangle of cells.

Inputs:
- key: The picker's key (`ldtk-picker-<key>`)
- tileset: The tileset's uid
- selected: The rectangle shown picked (pixels), nil none
- edit: The edit a selection sends
- tagged: Tiles shown tagged (Tags mode), and their color
*/
@(private)
tilesetPicker :: proc(c: ^LDtkTabCtx, key: string, tileset: int, selected: Maybe([4]int), edit: LDtk_Edit, mode := PickerMode.Rect, tagged: []int = nil, tagColor: u32 = 0, marked: []int = nil, small := false) -> skald.View {
	ctx := c.ctx
	th := ctx.theme
	main := c.main
	td := LDtkDoc_DefByUid(c.doc, "tilesets", tileset)
	if td < 0 do return uiText(th, .Muted, "No such tileset")
	rel := Json_String(main, Json_Get(main, td, "relPath"))
	if rel == "" && Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do rel = "finalbossblues-icons_full_16.png"
	path := joinPath(LDtkDoc_Folder(c.doc), rel, allocator = context.temp_allocator)
	if rel == "" || !os.exists(path) {
		if Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do return uiText(th, .Muted, "LDtk's internal icons are LDtk's own image (FinalBossBlues' icons): put a copy of finalbossblues-icons_full_16.png beside the .ldtk file to see and pick them here.", max_width = c.rowWidth)
		return uiText(th, .Muted, "The tileset's image can't be read.", color = th.color.warning)
	}
	size := [2]f32{f32(Json_Int(main, Json_Get(main, td, "pxWid"))), f32(Json_Int(main, Json_Get(main, td, "pxHei")))}
	grid := f32(max(Json_Int(main, Json_Get(main, td, "tileGridSize"), 16), 1))
	spacing := f32(Json_Int(main, Json_Get(main, td, "spacing")))
	padding := f32(Json_Int(main, Json_Get(main, td, "padding")))
	cWid := max(Json_Int(main, Json_Get(main, td, "__cWid")), 1)
	cHei := max(Json_Int(main, Json_Get(main, td, "__cHei")), 1)
	widest := small ? min(c.rowWidth - (c.stacked ? 0 : LDTK_LABEL_WIDTH + th.spacing.sm), 160) : c.rowWidth
	zoom := min(widest / max(size.x, 1), small ? 4 : 3)
	if size.y * zoom > 360 do zoom = 360 / max(size.y, 1)
	zoom = max(zoom, 0.25)
	pickerKey := fmt.tprintf("ldtk-picker-%s", key)
	id := skald.hash_id(pickerKey)
	cellAt :: proc(ctx: ^skald.Ctx(Msg), id: skald.Widget_ID, zoom, grid, spacing, padding: f32, cWid, cHei: int) -> ([2]int, bool) {
		st, ok := ctx.widgets.states[id]
		if !ok do return {}, false
		r := st.last_rect
		local := (ctx.input.mouse_pos - {r.x, r.y}) / zoom
		cx := int(math.floor((local.x - padding) / (grid + spacing)))
		cy := int(math.floor((local.y - padding) / (grid + spacing)))
		return {clamp(cx, 0, cWid - 1), clamp(cy, 0, cHei - 1)}, true
	}
	hovered := skald.widget_hovered(ctx, id) && !skald.mouse_over_overlay(ctx) && len(ctx.widgets.overlay_rects_prev) == 0
	if st, ok := ctx.widgets.states[id]; ok && st.clip_rect.w > 0 {
		m := ctx.input.mouse_pos
		r := st.clip_rect
		if m.x < r.x || m.y < r.y || m.x >= r.x + r.w || m.y >= r.y + r.h do hovered = false
	}
	drag, has := &pickerDrags[pickerKey]
	if !has {
		pickerDrags[strings.clone(pickerKey)] = {}
		drag = &pickerDrags[pickerKey]
	}
	if hovered && (ctx.input.mouse_pressed[.Left] || ctx.input.mouse_pressed[.Right]) && !drag.dragging {
		if cell, ok := cellAt(ctx, id, zoom, grid, spacing, padding, cWid, cHei); ok do drag^ = {dragging = true, right = !ctx.input.mouse_pressed[.Left], start = cell}
	}
	box: [4]int
	if drag.dragging {
		cell, _ := cellAt(ctx, id, zoom, grid, spacing, padding, cWid, cHei)
		box = {min(drag.start.x, cell.x), min(drag.start.y, cell.y), max(drag.start.x, cell.x), max(drag.start.y, cell.y)}
		if mode == .Tile do box = {cell.x, cell.y, cell.x, cell.y}
		if !ctx.input.mouse_buttons[.Left] && !ctx.input.mouse_buttons[.Right] {
			drag.dragging = false
			e := edit
			switch mode {
			case .Rect:
				// TilesetDef.getTileRectFromTileIds: the cells' sources and the last one's far edge
				x := int(padding) + box[0] * int(grid + spacing)
				y := int(padding) + box[1] * int(grid + spacing)
				right := int(padding) + box[2] * int(grid + spacing) + int(grid)
				bottom := int(padding) + box[3] * int(grid + spacing) + int(grid)
				e.text = fmt.tprintf("%d,%d,%d,%d", x, y, right - x, bottom - y)
				skald.send(ctx, Msg(e))
			case .Tags:
				ids := make([dynamic]int, context.temp_allocator)
				for cy in box[1] ..= box[3] do for cx in box[0] ..= box[2] do append(&ids, cx + cy * cWid)
				e.ids = ids[:]
				e.flag = !drag.right
				skald.send(ctx, Msg(e))
			case .Tile:
				skald.send(ctx, Msg(LDtk_Def_Picked{what = .Data_Tile, uid = box[0] + box[1] * cWid}))
			}
		} else {
			skald.send(ctx, Msg(Frame_Requested{}))
		}
	}
	Paint :: struct {
		image: string,
		size: [2]f32,
		zoom, grid, spacing, padding: f32,
		cWid: int,
		selected: [4]int,
		hasSelected, dragging: bool,
		box: [4]int,
		tagged, marked: []int,
		tagColor, accent: skald.Color,
	}
	p := new(Paint, context.temp_allocator)
	p^ = {image = strings.clone(path, context.temp_allocator), size = size, zoom = zoom, grid = grid, spacing = spacing, padding = padding, cWid = cWid,
		dragging = drag.dragging, box = box, accent = th.color.primary, tagColor = skald.rgb(tagColor)}
	if r, ok := selected.?; ok do p.selected, p.hasSelected = r, true
	if tagged != nil do p.tagged = slice.clone(tagged, context.temp_allocator)
	if marked != nil do p.marked = slice.clone(marked, context.temp_allocator)
	canvas := skald.canvas(ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		r := painter.r
		b := painter.bounds
		skald.draw_rect(r, b, {0.1, 0.1, 0.12, 1})
		skald.draw_image_region(r, p.image, {b.x, b.y, p.size.x * p.zoom, p.size.y * p.zoom}, {0, 0, p.size.x, p.size.y}, inset = false)
		cell :: proc(p: ^Paint, b: skald.Rect, id: int) -> skald.Rect {
			cx, cy := id % max(p.cWid, 1), id / max(p.cWid, 1)
			step := (p.grid + p.spacing) * p.zoom
			return {b.x + p.padding * p.zoom + f32(cx) * step, b.y + p.padding * p.zoom + f32(cy) * step, p.grid * p.zoom, p.grid * p.zoom}
		}
		for id in p.tagged {
			c := cell(p, b, id)
			skald.draw_rect(r, c, {p.tagColor.r, p.tagColor.g, p.tagColor.b, 0.35})
			skald.draw_rect_outline(r, c, 2, p.tagColor)
		}
		for id in p.marked {
			c := cell(p, b, id)
			skald.draw_rect_outline(r, {c.x + 1, c.y + 1, c.w - 2, c.h - 2}, 1, {1, 1, 1, 0.8})
		}
		if p.hasSelected {
			s := p.selected
			rect := skald.Rect{b.x + f32(s[0]) * p.zoom, b.y + f32(s[1]) * p.zoom, f32(s[2]) * p.zoom, f32(s[3]) * p.zoom}
			skald.draw_rect_outline(r, {rect.x - 1, rect.y - 1, rect.w + 2, rect.h + 2}, 1, {0, 0, 0, 0.8})
			skald.draw_rect_outline(r, rect, 2, p.accent)
		}
		if p.dragging {
			a := cell(p, b, p.box[0] + p.box[1] * p.cWid)
			z := cell(p, b, p.box[2] + p.box[3] * p.cWid)
			skald.draw_rect_outline(r, {a.x, a.y, z.x + z.w - a.x, z.y + z.h - a.y}, 2, {1, 1, 1, 0.9})
		}
	}, id = id, width = size.x * zoom, height = size.y * zoom, cursor = .Crosshair)
	return skald.row(skald.spacer(c.stacked || !small ? 0 : LDTK_LABEL_WIDTH), canvas, spacing = th.spacing.sm)
}

// --- Entities ----------------------------------------------------------------------------------

/*
The Entities tab's definitions (EditEntityDefs): the list's buttons and presets, the selected
type's settings (size, shape and look, limits, tags), then its fields (`defsFields`).
*/
LDtkDefs_Entities :: proc(c: ^LDtkTabCtx) -> int {
	main := c.main
	add := tabBase(c, .Def_Added)
	add.kind = .Entity
	rect, circle := add, add
	rect.text, circle.text = "RectRegion", "CircleRegion"
	// The toolbar row: a new type (LDtk's presets), then the list's buttons
	tabTool(c, "ldtk-entities-add", ICON_PLUS, "A new entity type", Msg(add), label = "Entity")
	tabTool(c, "ldtk-entities-add-rect", ICON_PLUS, "A new rectangle region (LDtk's preset: a resizable, hollow rectangle)", Msg(rect), label = "Rectangle")
	tabTool(c, "ldtk-entities-add-circle", ICON_PLUS, "A new circle region (LDtk's preset)", Msg(circle), label = "Circle")
	c.list.empty = "No entity types: + adds one."
	def := tabItemChoice(c, .Entities, LDtkDoc_Defs(c.doc, "entities"), c.s.level.entityDef)
	if def < 0 {
		tabNote(c, "This project has no entity types: add one (the buttons above).")
		return -1
	}
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	items := Json_Items(main, LDtkDoc_Defs(c.doc, "entities"))
	at, _ := slice.linear_search(items, def)
	e := tabBase(c, .Def_Removed)
	e.kind, e.def = .Entity, uid
	listTools(c, "entities", "entity type", e, at, len(items))
	c.list.text = fmt.tprintf("%s: %d of %d", Json_String(main, Json_Get(main, def, "identifier")), at + 1, len(items))
	placed := len(ldtkEntitiesOf(c.doc, uid))
	if placed > 0 do tabNote(c, fmt.tprintf("%d placed: deleting the type removes them from every level (and references to them).", placed))
	edit :: proc(c: ^LDtkTabCtx, op: LDtkEditOp, uid: int) -> LDtk_Edit { x := tabBase(c, op); x.def = uid; return x }
	tabRow(c, "Name", tabTextField(c, "ldtk-entity-name", Json_String(main, Json_Get(main, def, "identifier")), edit(c, .Entity_Name, uid)), "The entity type's identifier: scripts named like it run on its entities (scenes' rules follow a rename; code doesn't)")
	memberText(c, "Documentation", "A note about the type (empty: none)", .Entity, uid, "doc", Json_String(main, Json_Get(main, def, "doc")))
	memberText(c, "Tags", "Tags of the type, separated by commas: layers and references can filter by them", .Entity, uid, "tags", tagsText(main, Json_Get(main, def, "tags")))

	tabHeading(c, "Size and shape")
	memberNumber(c, "Width", "The type's width in pixels, 1 to 2048 (entities not resized follow it)", .Entity, uid, "width", Json_Float(main, Json_Get(main, def, "width"), 16), 1, 0, 1, 2048)
	memberNumber(c, "Height", "The type's height in pixels, 1 to 2048", .Entity, uid, "height", Json_Float(main, Json_Get(main, def, "height"), 16), 1, 0, 1, 2048)
	resX, resY := Json_Bool(main, Json_Get(main, def, "resizableX")), Json_Bool(main, Json_Get(main, def, "resizableY"))
	memberFlag(c, "Resizable across", "Whether its entities can be made wider or narrower in a level", .Entity, uid, "resizableX", resX)
	memberFlag(c, "Resizable down", "Whether its entities can be made taller or shorter", .Entity, uid, "resizableY", resY)
	if resX && resY do memberFlag(c, "Keep aspect", "Whether a resize keeps its width and height in proportion", .Entity, uid, "keepAspectRatio", Json_Bool(main, Json_Get(main, def, "keepAspectRatio")))
	if resX {
		memberText(c, "Min width", "The smallest it may be made, in pixels (empty: none)", .Entity, uid, "minWidth", numberText(main, Json_Get(main, def, "minWidth")))
		memberText(c, "Max width", "The largest (empty: none)", .Entity, uid, "maxWidth", numberText(main, Json_Get(main, def, "maxWidth")))
	}
	if resY {
		memberText(c, "Min height", "The shortest it may be made (empty: none)", .Entity, uid, "minHeight", numberText(main, Json_Get(main, def, "minHeight")))
		memberText(c, "Max height", "The tallest (empty: none)", .Entity, uid, "maxHeight", numberText(main, Json_Get(main, def, "maxHeight")))
	}
	tabNumberRow(c, "Pivot X", "ldtk-entity-pivot-x", "Where the entity's position is across it: 0 left, 0.5 middle, 1 right", edit(c, .Entity_Pivot_X, uid), Json_Float(main, Json_Get(main, def, "pivotX"), 0.5), 0.5, 1, 0, 1)
	tabNumberRow(c, "Pivot Y", "ldtk-entity-pivot-y", "Where it is up and down: 0 top, 0.5 middle, 1 bottom", edit(c, .Entity_Pivot_Y, uid), Json_Float(main, Json_Get(main, def, "pivotY"), 0.5), 0.5, 1, 0, 1)

	tabHeading(c, "Look")
	tabRow(c, "Color", tabColorField(c, "ldtk-entity-color", Json_String(main, Json_Get(main, def, "color")), edit(c, .Entity_Color, uid)), "The type's color, #RRGGBB (its outline in LDtk and here)")
	// Render as: a shape, a tileset's tiles, LDtk's icons (EditEntityDefs' render select)
	renderLabels := make([dynamic]string, context.temp_allocator)
	renderValues := make([dynamic]string, context.temp_allocator)
	append(&renderLabels, "Rectangle", "Ellipse", "Cross")
	append(&renderValues, "!Rectangle", "!Ellipse", "!Cross")
	hasIcons := false
	for td in Json_Items(main, LDtkDoc_Defs(c.doc, "tilesets")) {
		if Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" {
			hasIcons = true
			append(&renderLabels, "LDtk's internal icons")
			append(&renderValues, "LdtkIcons")
			continue
		}
		append(&renderLabels, fmt.tprintf("Tiles of %s", Json_String(main, Json_Get(main, td, "identifier"))))
		append(&renderValues, fmt.tprint(Json_Int(main, Json_Get(main, td, "uid"))))
	}
	if !hasIcons {
		append(&renderLabels, "LDtk's internal icons")
		append(&renderValues, "LdtkIcons")
	}
	mode := Json_String(main, Json_Get(main, def, "renderMode"))
	current := fmt.tprintf("!%s", mode)
	tileset := Json_Int(main, Json_Get(main, def, "tilesetId"), -1)
	if mode == "Tile" && tileset >= 0 {
		current = fmt.tprint(tileset)
		if Json_String(main, Json_Get(main, LDtkDoc_DefByUid(c.doc, "tilesets", tileset), "embedAtlas")) == "LdtkIcons" do current = "LdtkIcons"
	}
	memberChoice(c, "Drawn as", "Its shape, or a tile of a tileset (LDtk's icons make their tileset)", .Entity, uid, "render", labelOf(renderLabels[:], renderValues[:], current), renderLabels[:], renderValues[:])
	if mode == "Tile" && tileset >= 0 {
		tabRow(c, "Tile", skald.text(rectText(main, Json_Get(main, def, "tileRect")), c.ctx.theme.color.fg, c.ctx.theme.font.size_xs), "The tile it shows: drag over the tileset below")
		append(c.rows, tilesetPicker(c, "entity-tile", tileset, rectOf(main, Json_Get(main, def, "tileRect")), defEdit(c, .Entity, uid, "tileRect")))
		tileModes := []string{"Cover", "FitInside", "Repeat", "Stretch", "FullSizeCropped", "FullSizeUncropped", "NineSlice"}
		modeLabels := []string{"Cover bounds", "Fit inside bounds", "Repeat", "Dirty stretch to bounds", "Full size (cropped in bounds)", "Full size (not cropped)", "9-slices scaling"}
		trm := Json_String(main, Json_Get(main, def, "tileRenderMode"))
		memberChoice(c, "Tile fits", "How the tile fills the entity's box", .Entity, uid, "tileRenderMode", labelOf(modeLabels, tileModes, trm), modeLabels, tileModes)
		if trm == "NineSlice" {
			borders := Json_Items(main, Json_Get(main, def, "nineSliceBorders"))
			sides := []string{"Border up", "Border right", "Border down", "Border left"}
			for side, i in sides {
				value := i < len(borders) ? Json_Float(main, borders[i]) : 2
				x := defEdit(c, .Entity, uid, "nineSliceBorders")
				x.index = i
				tabNumberRow(c, side, fmt.tprintf("ldtk-entity-nineSlice-%d", i), "A 9-slice border, in pixels of the tile (the first sets the others while they're the same)", x, value, 1, 0, 1, 100000)
			}
		}
		memberNumber(c, "Tile opacity", "How opaque the tile draws, 0 to 1", .Entity, uid, "tileOpacity", Json_Float(main, Json_Get(main, def, "tileOpacity"), 1), 0.05, 2, 0, 1)
	}
	hollow := Json_Bool(main, Json_Get(main, def, "hollow"))
	memberFlag(c, "Hollow", "Whether clicks go through its middle (only its edge picks it)", .Entity, uid, "hollow", hollow)
	if !hollow do memberNumber(c, "Fill opacity", "How opaque its fill draws, 0 to 1", .Entity, uid, "fillOpacity", Json_Float(main, Json_Get(main, def, "fillOpacity"), 1), 0.05, 2, 0, 1)
	memberNumber(c, "Line opacity", "How opaque its outline draws, 0 to 1", .Entity, uid, "lineOpacity", Json_Float(main, Json_Get(main, def, "lineOpacity"), 1), 0.05, 2, 0, 1)
	memberFlag(c, "Show name", "Whether LDtk writes the type's name by its entities", .Entity, uid, "showName", Json_Bool(main, Json_Get(main, def, "showName"), true))
	tsLabels, tsValues := defChoices(c, LDtkDoc_Defs(c.doc, "tilesets"), "Its own look")
	uiTile := Json_Get(main, def, "uiTileRect")
	uiTs := Json_Kind(main, uiTile) == .Object ? fmt.tprint(Json_Int(main, Json_Get(main, uiTile, "tilesetUid"))) : ""
	memberChoice(c, "Editor tile", "A tile LDtk shows for the type in its lists instead of its look", .Entity, uid, "uiTileset", labelOf(tsLabels, tsValues, uiTs), tsLabels, tsValues)
	if uiTs != "" {
		n, _ := strconv.parse_int(uiTs)
		shown := rectOf(main, uiTile)
		if r, ok := shown.?; ok && r[2] == 0 do shown = nil
		append(c.rows, tilesetPicker(c, "entity-ui-tile", n, shown, defEdit(c, .Entity, uid, "uiTileRect")))
	}

	tabHeading(c, "Limits")
	maxCount := Json_Int(main, Json_Get(main, def, "maxCount"))
	memberNumber(c, "Max count", "How many may be placed (0: no limit)", .Entity, uid, "maxCount", f64(maxCount), 1, 0, 0, 1024)
	if maxCount > 0 {
		scopes := []string{"PerLayer", "PerLevel", "PerWorld"}
		scopeLabels := []string{"Per layer", "Per level", "In the world"}
		memberChoice(c, "Counted", "Where the limit counts them", .Entity, uid, "limitScope", labelOf(scopeLabels, scopes, Json_String(main, Json_Get(main, def, "limitScope"))), scopeLabels, scopes)
		behaviors := []string{"DiscardOldOnes", "PreventAdding", "MoveLastOne"}
		behaviorLabels := []string{"Discard older ones", "Prevent adding more", "Move the last one instead"}
		memberChoice(c, "At the limit", "What placing one more does", .Entity, uid, "limitBehavior", labelOf(behaviorLabels, behaviors, Json_String(main, Json_Get(main, def, "limitBehavior"))), behaviorLabels, behaviors)
	}
	memberFlag(c, "Out of bounds", "Whether its entities may be placed outside their level", .Entity, uid, "allowOutOfBounds", Json_Bool(main, Json_Get(main, def, "allowOutOfBounds")))
	memberFlag(c, "Table of contents", "Whether the project lists every one of them (LDtk's table of contents: games find them without reading levels)", .Entity, uid, "exportToToc", Json_Bool(main, Json_Get(main, def, "exportToToc")))

	defsFields(c, uid)
	return def
}

// A tile rectangle as text ("16, 0, 16 x 16"; "none")
@(private="file")
rectText :: proc(json: ^JsonDoc, node: int) -> string {
	r, ok := rectOf(json, node).?
	if !ok do return "None: drag over the tileset below"
	return fmt.tprintf("%d, %d, %d x %d px", r[0], r[1], r[2], r[3])
}

// --- Fields -----------------------------------------------------------------------------------

// The field types LDtk offers (FieldDefsForm's type picker; references and points only for entities)
@(private="file")
FIELD_TYPES := [?][2]string{
	{"F_Int", "Integer"}, {"F_Float", "Float"}, {"F_Bool", "Boolean"}, {"F_String", "String"}, {"F_Text", "Multilines"},
	{"F_Color", "Color"}, {"F_Path", "File path"}, {"F_Tile", "Tile"}, {"F_EntityRef", "Entity ref"}, {"F_Point", "Point"},
}

/*
A list of field definitions (FieldDefsForm): entity's (`entity` its uid) or the levels' (-1):
Add by type (single or array), the list's buttons, the type's conversions, then the selected
field's settings.
*/
@(private="file")
defsFields :: proc(c: ^LDtkTabCtx, entity: int) {
	tk := uiTokens(c.ctx)
	main := c.main
	level := entity < 0
	tabHeading(c, level ? "Level fields" : "Fields")
	list := level ? LDtkDoc_Defs(c.doc, "levelFields") : Json_Get(main, LDtkDoc_DefByUid(c.doc, "entities", entity), "fieldDefs")
	prefix := level ? "level-fields" : "fields"
	// Add: a type and single or array (the enums are types too)
	labels := make([dynamic]string, context.temp_allocator)
	values := make([dynamic]string, context.temp_allocator)
	for t in FIELD_TYPES {
		if level && (t[0] == "F_EntityRef" || t[0] == "F_Point") do continue
		append(&labels, t[1], fmt.tprintf("%s (array)", t[1]))
		append(&values, t[0], fmt.tprintf("%s[]", t[0]))
	}
	for l in ([]string{"enums", "externalEnums"}) do for d in Json_Items(main, LDtkDoc_Defs(c.doc, l)) {
		name := Json_String(main, Json_Get(main, d, "identifier"))
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		append(&labels, fmt.tprintf("Enum %s", name), fmt.tprintf("Enum %s (array)", name))
		append(&values, fmt.tprintf("F_Enum(%d)", uid), fmt.tprintf("F_Enum(%d)[]", uid))
	}
	add := tabBase(c, .Def_Added)
	add.kind, add.def = .Field, entity
	Add :: struct { edit: LDtk_Edit }
	pick := labeledSelect(c.ctx, "Add a field...", labels[:], values[:], Add{add}, proc(a: Add, v: string) -> Msg {
		e := a.edit
		e.flag = strings.has_suffix(v, "[]")
		e.text = strings.trim_suffix(v, "[]")
		return e
	}, id = skald.hash_id(fmt.tprintf("ldtk-%s-add", prefix)), width = c.controlWidth)
	tabRow(c, "New field", pick, "Add a field of a type to the definition (LDtk's + Single value and + Array)")
	if Json_Count(main, list) == 0 {
		tabNote(c, level ? "The levels have no fields yet." : "The type has no fields yet.")
		return
	}
	tab := level ? BottomTab.Level : BottomTab.Entities
	selected := level ? c.s.level.levelField : c.s.level.fieldDef
	// The field choice (by uid, the first when it's gone)
	names := make([dynamic]string, context.temp_allocator)
	uids := make([dynamic]string, context.temp_allocator)
	node := -1
	for f in Json_Items(main, list) {
		uid := Json_Int(main, Json_Get(main, f, "uid"))
		append(&names, fmt.tprintf("%s (%s)", Json_String(main, Json_Get(main, f, "identifier")), Json_String(main, Json_Get(main, f, "__type"))))
		append(&uids, fmt.tprint(uid))
		if node < 0 || uid == selected do node = f
	}
	uid := Json_Int(main, Json_Get(main, node, "uid"))
	Pick :: struct { level: bool }
	_ = tab
	choice := labeledSelect(c.ctx, fmt.tprint(uid), names[:], uids[:], Pick{level}, proc(p: Pick, v: string) -> Msg {
		n, _ := strconv.parse_int(v)
		return LDtk_Def_Picked{what = p.level ? .Level_Field : .Field, uid = n}
	}, id = skald.hash_id(level ? "ldtk-item-Level_Fields" : "ldtk-item-Fields"), width = c.controlWidth)
	tabRow(c, "Field", choice, "Which field the rows below edit")
	items := Json_Items(main, list)
	at, _ := slice.linear_search(items, node)
	e := tabBase(c, .Def_Removed)
	e.kind, e.field = .Field, uid
	info := LDtkDoc_FieldInfo(c.doc, node)
	// Its conversions (FieldTypeConverter)
	convLabels := make([dynamic]string, context.temp_allocator)
	convValues := make([dynamic]string, context.temp_allocator)
	for conv in LDtk_Conversions(info) {
		append(&convLabels, conv.lossless ? conv.label : fmt.tprintf("%s: values may change", conv.label))
		append(&convValues, conv.id)
	}
	extra := make([dynamic]skald.View, context.temp_allocator)
	if len(convLabels) > 0 {
		conv := tabBase(c, .Field_Converted)
		conv.field = uid
		append(&extra, labeledSelect(c.ctx, "Convert...", convLabels[:], convValues[:], conv, proc(e: LDtk_Edit, v: string) -> Msg {
			x := e
			x.text = v
			return x
		}, id = skald.hash_id(fmt.tprintf("ldtk-%s-convert", prefix)), width = tk.fieldM))
	}
	listButtons(c, prefix, e, at, len(items), ..extra[:])
	defsFieldForm(c, node, info, entity)
}

/*
A field definition's settings (FieldDefsForm.updateForm): its name and type, its default by type,
nullability, range, array limits, the type's own settings (a String's regular expression, a
Multilines field's language, a FilePath's types, a Tile field's tileset and default tile, a
reference's rules), and how LDtk shows it.
*/
@(private="file")
defsFieldForm :: proc(c: ^LDtkTabCtx, node: int, info: LDtkFieldInfo, entity: int) {
	main := c.main
	th := c.ctx.theme
	uid := info.uid
	level := entity < 0
	name := tabBase(c, .Field_Name)
	name.field = uid
	tabRow(c, "Name", tabTextField(c, fmt.tprintf("ldtk-field-name-%d", uid), info.identifier, name), "The field's identifier: games read it by name (scripts' fields named like it take its value)")
	tabRow(c, "Type", uiText(th, .Value, Json_String(main, Json_Get(main, node, "__type"))), "The field's type (Convert changes it where LDtk can)")
	memberText(c, "Documentation", "A note about the field (empty: none)", .Field, uid, "doc", Json_String(main, Json_Get(main, node, "doc")))

	// The default, by type
	over := Json_Get(main, node, "defaultOverride")
	param := Json_At(main, Json_Get(main, over, "params"), 0)
	defaultText := ""
	if Json_Kind(main, param) == .String do defaultText = Json_String(main, param)
	else if Json_Kind(main, param) == .Number do defaultText = Json_Text(main, param)
	def := defEdit(c, .Field, uid, "defaultOverride")
	if !info.isArray {
		#partial switch info.type {
		case .Int, .Float, .String, .Text, .Point:
			tabRow(c, "Default", tabTextField(c, fmt.tprintf("ldtk-field-default-%d", uid), defaultText, def), "The value of an entity (or level) with none of its own (empty: none)")
		case .Color:
			shown := ""
			if Json_Kind(main, param) == .Number do shown = LDtk_FormatColor(Json_Int(main, param))
			tabRow(c, "Default", tabColorField(c, fmt.tprintf("ldtk-field-default-%d", uid), shown, def), "The color of one without its own, #RRGGBB")
		case .Bool:
			box := skald.checkbox(c.ctx, Json_Kind(main, param) == .True, "", def, proc(e: LDtk_Edit, v: bool) -> Msg {
				x := e
				x.text = v ? "true" : "false"
				return x
			}, id = skald.hash_id(fmt.tprintf("ldtk-field-default-%d", uid)))
			tabRow(c, "Default", box, "The value of one without its own")
		case .Enum:
			values := LDtkDoc_EnumValues(c.doc, info.enumUid)
			labels := make([dynamic]string, context.temp_allocator)
			vals := make([dynamic]string, context.temp_allocator)
			append(&labels, info.canBeNull ? "(null)" : "(no default)")
			append(&vals, "")
			append(&labels, ..values)
			append(&vals, ..values)
			tabRow(c, "Default", tabChoiceField(c, fmt.tprintf("ldtk-field-default-%d", uid), defaultText == "" ? labels[0] : defaultText, labels[:], vals[:], def), "The value of one without its own")
		case .Tile:
		case:
			tabNote(c, "   No default for this type (LDtk has none).")
		}
	}
	memberFlag(c, "Can be null", "Whether a value may be left empty (null) rather than the type's zero", .Field, uid, "canBeNull", info.canBeNull)
	if info.type == .Int || info.type == .Float {
		memberText(c, "Min", "The smallest value (empty: none; a reversed range is swapped)", .Field, uid, "min", numberText(main, Json_Get(main, node, "min")))
		memberText(c, "Max", "The largest value (empty: none)", .Field, uid, "max", numberText(main, Json_Get(main, node, "max")))
	}
	if info.isArray {
		memberText(c, "Min items", "The fewest items an array should have (empty: none)", .Field, uid, "arrayMinLength", numberText(main, Json_Get(main, node, "arrayMinLength")))
		memberText(c, "Max items", "The most (empty: none)", .Field, uid, "arrayMaxLength", numberText(main, Json_Get(main, node, "arrayMaxLength")))
	}
	#partial switch info.type {
	case .String:
		regex := Json_String(main, Json_Get(main, node, "regex"))
		memberText(c, "Regular expression", "What values keep: only the parts matching it (empty: everything)", .Field, uid, "regex", regexContent(regex))
		if regex != "" do memberFlag(c, "Ignore case", "The regular expression's i flag", .Field, uid, "regexFlagI", strings.contains(regexFlags(regex), "i"))
	case .Text:
		langs := []string{"", "LangJson", "LangXml", "LangMarkdown", "LangLog", "LangPython", "LangRuby", "LangC", "LangHaxe", "LangJS", "LangLua"}
		langLabels := []string{"Plain text", "JSON", "XML/HTML", "Markdown", "Log file", "Python", "Ruby", "C/C++/C#", "Haxe", "Javascript", "Lua"}
		memberChoice(c, "Language", "How LDtk's text editor colors the value", .Field, uid, "textLanguageMode", labelOf(langLabels, langs, Json_String(main, Json_Get(main, node, "textLanguageMode"))), langLabels, langs)
	case .Path:
		types := make([dynamic]string, context.temp_allocator)
		for t in Json_Items(main, Json_Get(main, node, "acceptFileTypes")) do append(&types, Json_String(main, t))
		memberText(c, "File types", "The extensions a path may have, separated by spaces (empty: any)", .Field, uid, "acceptFileTypes", strings.join(types[:], " ", context.temp_allocator))
	case .Tile:
		tsLabels, tsValues := defChoices(c, LDtkDoc_Defs(c.doc, "tilesets"), "No tileset")
		ts := uidText(main, Json_Get(main, node, "tilesetUid"))
		memberChoice(c, "Tileset", "The tileset its tiles come from", .Field, uid, "tilesetUid", labelOf(tsLabels, tsValues, ts), tsLabels, tsValues)
		if ts != "" && !info.isArray {
			n, _ := strconv.parse_int(ts)
			shown: Maybe([4]int)
			if r, ok := LDtk_ParseRect(defaultText); ok do shown = r
			tabRow(c, "Default tile", skald.text(defaultText == "" ? "None: drag over the tileset below" : defaultText, th.color.fg, th.font.size_xs), "The tile of one without its own (picking one makes the field nullable, as LDtk does)")
			append(c.rows, tilesetPicker(c, fmt.tprintf("field-default-%d", uid), n, shown, def))
			if defaultText != "" {
				clear := def
				clear.text = ""
				buttonRow(c, smallButton(c, fmt.tprintf("ldtk-field-default-clear-%d", uid), "No default tile", Msg(clear)))
			}
		}
	case .EntityRef:
		refs := []string{"Any", "OnlySame", "OnlyTags", "OnlySpecificEntity"}
		ownerName := entity >= 0 ? Json_String(main, Json_Get(main, entity, "identifier")) : "entity"
		refLabels := []string{"Any entity", fmt.tprintf("Only another %s", ownerName), "Any entity with one of the tags", "Only a specific entity type"}
		memberChoice(c, "Points at", "Which entities a reference may point at", .Field, uid, "allowedRefs", labelOf(refLabels, refs, info.allowedRefs), refLabels, refs)
		switch info.allowedRefs {
		case "OnlySpecificEntity":
			eLabels, eValues := defChoices(c, LDtkDoc_Defs(c.doc, "entities"))
			memberChoice(c, "Entity type", "The type it points at", .Field, uid, "allowedRefsEntityUid", labelOf(eLabels, eValues, uidText(main, Json_Get(main, node, "allowedRefsEntityUid"))), eLabels, eValues)
		case "OnlyTags":
			memberText(c, "Tags", "Entity types with one of these tags, separated by commas", .Field, uid, "allowedRefTags", tagsText(main, Json_Get(main, node, "allowedRefTags")))
		case "OnlySame":
			memberFlag(c, "Symmetrical", "Whether the entity pointed at points back", .Field, uid, "symmetricalRef", info.symmetrical)
		}
		memberFlag(c, "Other levels", "Whether a reference may point at an entity in another level", .Field, uid, "allowOutOfLevelRef", info.outOfLevel)
		memberFlag(c, "Chain", "Whether LDtk keeps picking the next reference after one (arrays)", .Field, uid, "autoChainRef", Json_Bool(main, Json_Get(main, node, "autoChainRef"), true))
	}

	// How LDtk shows it (the modes allowed for the type)
	tabHeading(c, "Display")
	modeLabel :: proc(mode: string) -> string {
		switch mode {
		case "Hidden": return "Do not show"
		case "ValueOnly": return "Value only"
		case "NameAndValue": return "Name and value"
		case "EntityTile": return "Replace the entity's tile"
		case "LevelTile": return "Replace the level in the world view"
		case "Points": return "Isolated points"
		case "PointStar": return "Star of points"
		case "PointPath": return "Path of points"
		case "PointPathLoop": return "Path of points (loop)"
		case "RadiusPx": return "A radius (pixels)"
		case "RadiusGrid": return "A radius (cells)"
		case "ArrayCountWithLabel": return "Array length with its name"
		case "ArrayCountNoLabel": return "Array length"
		case "RefLinkBetweenPivots": return "A link (pivots)"
		case "RefLinkBetweenCenters": return "A link (centers)"
		}
		return mode
	}
	labels := make([dynamic]string, context.temp_allocator)
	values := make([dynamic]string, context.temp_allocator)
	for m in LDTK_DISPLAY_MODES do if LDtk_DisplayModeAllowed(info, !level, m) {
		append(&labels, modeLabel(m))
		append(&values, m)
	}
	mode := Json_String(main, Json_Get(main, node, "editorDisplayMode"))
	memberChoice(c, "Shown as", "How LDtk shows the field in levels", .Field, uid, "editorDisplayMode", labelOf(labels[:], values[:], mode), labels[:], values[:])
	switch mode {
	case "ValueOnly", "NameAndValue", "ArrayCountWithLabel", "ArrayCountNoLabel":
		if !level {
			positions := []string{"Above", "Center", "Beneath"}
			memberChoice(c, "Where", "Where LDtk writes it by the entity", .Field, uid, "editorDisplayPos", Json_String(main, Json_Get(main, node, "editorDisplayPos")), positions, positions)
		}
		memberNumber(c, "Text scale", "How big LDtk writes it, from 0.1", .Field, uid, "editorDisplayScale", Json_Float(main, Json_Get(main, node, "editorDisplayScale"), 1), 0.1, 2, 0.1, 100)
	}
	switch mode {
	case "PointStar", "PointPath", "PointPathLoop", "RefLinkBetweenPivots", "RefLinkBetweenCenters":
		styles := []string{"ZigZag", "StraightArrow", "CurvedArrow", "ArrowsLine", "DashedLine"}
		styleLabels := []string{"Zig-zag", "Straight arrow", "Curved arrow", "Line of arrows", "Dashed line"}
		memberChoice(c, "Line", "How LDtk draws the line", .Field, uid, "editorLinkStyle", labelOf(styleLabels, styles, Json_String(main, Json_Get(main, node, "editorLinkStyle"))), styleLabels, styles)
	}
	if mode != "Hidden" && mode != "EntityTile" && mode != "LevelTile" {
		memberColor(c, "Display color", "The color LDtk shows it in (empty: the entity's)", .Field, uid, "editorDisplayColor", Json_String(main, Json_Get(main, node, "editorDisplayColor")))
	}
	if mode != "Hidden" do memberFlag(c, "Always shown", "Whether LDtk shows it when its entity isn't selected", .Field, uid, "editorAlwaysShow", Json_Bool(main, Json_Get(main, node, "editorAlwaysShow")))
	if level do memberFlag(c, "In the world view", "Whether LDtk's world view shows it", .Field, uid, "editorShowInWorld", Json_Bool(main, Json_Get(main, node, "editorShowInWorld"), true))
	memberFlag(c, "Cut long values", "Whether LDtk shortens long values", .Field, uid, "editorCutLongValues", Json_Bool(main, Json_Get(main, node, "editorCutLongValues"), true))
	if info.type == .Int || info.type == .Float {
		memberText(c, "Prefix", "Text LDtk writes before the number (kept as typed)", .Field, uid, "editorTextPrefix", Json_String(main, Json_Get(main, node, "editorTextPrefix")))
		memberText(c, "Suffix", "Text LDtk writes after it", .Field, uid, "editorTextSuffix", Json_String(main, Json_Get(main, node, "editorTextSuffix")))
	}
	memberFlag(c, "Gives the color", "Whether its value colors the entity or level (Color and enum fields: LDtk's smart color)", .Field, uid, "useForSmartColor", Json_Bool(main, Json_Get(main, node, "useForSmartColor")))
	if !level {
		if Json_Bool(main, Json_Get(main, entity, "exportToToc")) do memberFlag(c, "In the table of contents", "Whether its value is listed with the entity in the project's table of contents", .Field, uid, "exportToToc", Json_Bool(main, Json_Get(main, node, "exportToToc")))
		memberFlag(c, "Searchable", "Whether LDtk's search finds entities by it", .Field, uid, "searchable", Json_Bool(main, Json_Get(main, node, "searchable")))
	}
}

/*
The Level tab's level fields (EditLevelFieldDefs, which LDtk opens from its level panel): their
definitions with the same form as entities' fields.
*/
LDtkDefs_LevelFields :: proc(c: ^LDtkTabCtx) {
	defsFields(c, -1)
}

// --- Enums -----------------------------------------------------------------------------------

/*
The Enums tab (EditEnumDefs): the list's buttons, the selected enum's name, tags, icons and values
(name, color, icon, order, removal), new ones; external enum files: imported, synced, removed.
*/
LDtkDefs_Enums :: proc(c: ^LDtkTabCtx) {
	tk := uiTokens(c.ctx)
	main := c.main
	th := c.ctx.theme
	add := tabBase(c, .Def_Added)
	add.kind = .Enum
	tabTool(c, "ldtk-enums-add", ICON_PLUS, "A new enum", Msg(add), label = "Enum")
	// Local enums, then external ones (the list has both: an external one's file after its name)
	all := make([dynamic]int, context.temp_allocator)
	append(&all, ..Json_Items(main, LDtkDoc_Defs(c.doc, "enums")))
	append(&all, ..Json_Items(main, LDtkDoc_Defs(c.doc, "externalEnums")))
	def := -1
	for d in all {
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		if def < 0 || uid == c.s.level.enumDef do def = d
	}
	for d in all {
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		label := Json_String(main, Json_Get(main, d, "identifier"))
		rel := Json_String(main, Json_Get(main, d, "externalRelPath"))
		row := ColoredTreeRow{label = strings.clone(label, context.temp_allocator), icon = rel != "" ? ICON_LINK : ICON_LIST, selected = d == def}
		if rel != "" do row.label = fmt.tprintf("%s (%s)", label, filepath.base(rel))
		tabListItem(c, row, Msg(LDtk_Item_Picked{.Enums, uid}))
	}
	c.list.empty = "No enums: + adds one."
	if def >= 0 {
		uid := Json_Int(main, Json_Get(main, def, "uid"))
		c.list.text = fmt.tprintf("%s: %d value%s", Json_String(main, Json_Get(main, def, "identifier")), Json_Count(main, Json_Get(main, def, "values")), Json_Count(main, Json_Get(main, def, "values")) == 1 ? "" : "s")
		external := Json_Kind(main, Json_Get(main, def, "externalRelPath")) == .String
		cdb := external && strings.has_suffix(strings.to_lower(Json_String(main, Json_Get(main, def, "externalRelPath")), context.temp_allocator), ".cdb")
		used := ldtkEnumUsers(c, uid)
		if !external {
			locals := Json_Items(main, LDtkDoc_Defs(c.doc, "enums"))
			at, _ := slice.linear_search(locals, def)
			e := tabBase(c, .Def_Removed)
			e.kind, e.def = .Enum, uid
			listTools(c, "enums", "enum", e, at, len(locals))
			if used > 0 do tabNote(c, fmt.tprintf("%d field%s use it: deleting it deletes them too.", used, used == 1 ? "" : "s"), true)
			name := tabBase(c, .Enum_Name)
			name.def = uid
			tabRow(c, "Name", tabTextField(c, "ldtk-enum-name", Json_String(main, Json_Get(main, def, "identifier")), name), "The enum's identifier (fields of it follow a rename)")
			memberText(c, "Tags", "Tags of the enum, separated by commas (LDtk groups its lists by them)", .Enum, uid, "tags", tagsText(main, Json_Get(main, def, "tags")))
		} else {
			tabNote(c, fmt.tprintf("From the external file %s: its values are the file's (sync it below after the file changes).", Json_String(main, Json_Get(main, def, "externalRelPath"))))
		}
		icons := Json_Int(main, Json_Get(main, def, "iconTilesetUid"), -1)
		if !cdb {
			tsLabels, tsValues := defChoices(c, LDtkDoc_Defs(c.doc, "tilesets"), "No icons")
			memberChoice(c, "Icons' tileset", "The tileset its values' icons come from (another one clears them)", .Enum, uid, "iconTilesetUid", labelOf(tsLabels, tsValues, icons >= 0 ? fmt.tprint(icons) : ""), tsLabels, tsValues)
		}
		tabHeading(c, "Values")
		values := Json_Items(main, Json_Get(main, def, "values"))
		if len(values) == 0 do tabNote(c, "No values yet.")
		for v, i in values {
			e := tabBase(c, .Enum_Value_Name)
			e.def, e.index = uid, i
			if external {
				tabRow(c, fmt.tprintf("Value %d", i + 1), uiText(th, .Value, Json_String(main, Json_Get(main, v, "id"))), "A value of the file")
			} else {
				tabRow(c, fmt.tprintf("Value %d", i + 1), tabTextField(c, fmt.tprintf("ldtk-enum-value-%d", i), Json_String(main, Json_Get(main, v, "id")), e), "The value's name: fields set to it follow a rename")
			}
			if !cdb {
				e.op = .Enum_Value_Color
				tabRow(c, "   Color", tabColorField(c, fmt.tprintf("ldtk-enum-color-%d", i), LDtk_FormatColor(Json_Int(main, Json_Get(main, v, "color"))), e), "The value's color, #RRGGBB")
			}
			buttons := make([dynamic]skald.View, context.temp_allocator)
			if !external {
				up, down, remove := e, e, e
				up.op, down.op, remove.op = .Enum_Value_Moved, .Enum_Value_Moved, .Enum_Value_Removed
				up.number, down.number = -1, 1
				append(&buttons, smallButton(c, fmt.tprintf("ldtk-enum-up-%d", i), ICON_ARROW_UP, Msg(up), disabled = i == 0),
					smallButton(c, fmt.tprintf("ldtk-enum-down-%d", i), ICON_ARROW_DOWN, Msg(down), disabled = i == len(values) - 1),
					smallButton(c, fmt.tprintf("ldtk-enum-remove-%d", i), fmt.tprintf("%s  Remove", ICON_TRASH), Msg(remove)))
			}
			if icons >= 0 && !cdb {
				tile := tabBase(c, .Enum_Value_Tile)
				tile.def, tile.index = uid, i
				append(&buttons, smallButton(c, fmt.tprintf("ldtk-enum-icon-clear-%d", i), "No icon", Msg(tile), disabled = Json_Kind(main, Json_Get(main, v, "tileRect")) != .Object))
			}
			if len(buttons) > 0 do buttonRow(c, ..buttons[:])
			if icons >= 0 && !cdb {
				tile := tabBase(c, .Enum_Value_Tile)
				tile.def, tile.index = uid, i
				append(c.rows, tilesetPicker(c, fmt.tprintf("enum-icon-%d", i), icons, rectOf(main, Json_Get(main, v, "tileRect")), tile, small = true))
			}
		}
		if !external {
			value := tabBase(c, .Enum_Value_Added)
			value.def = uid
			value.text = strings.clone(c.s.level.newValue, context.temp_allocator)
			tabRow(c, "New value", skald.row(
				skald.text_input(c.ctx, strings.clone(c.s.level.newValue, context.temp_allocator), proc(v: string) -> Msg { return LDtk_New_Name_Typed{true, v} },
					id = skald.hash_id("ldtk-enum-new-value"), width = max(c.controlWidth - tk.fieldXS, tk.fieldXS), padding = tk.fieldPadding),
				smallButton(c, "ldtk-enum-add-value", "Add", Msg(value), disabled = strings.trim_space(c.s.level.newValue) == ""),
				spacing = th.spacing.xs, cross_align = .Center), "A value to add to the enum")
		}
	} else {
		tabNote(c, "This project has no enums yet.")
	}
	defsExternalEnums(c)
}

// How many field definitions use an enum
@(private="file")
ldtkEnumUsers :: proc(c: ^LDtkTabCtx, enumUid: int) -> int {
	n := 0
	for e in Json_Items(c.main, LDtkDoc_Defs(c.doc, "entities")) do for f in Json_Items(c.main, Json_Get(c.main, e, "fieldDefs")) {
		if info := LDtkDoc_FieldInfo(c.doc, f); info.type == .Enum && info.enumUid == enumUid do n += 1
	}
	for f in Json_Items(c.main, LDtkDoc_Defs(c.doc, "levelFields")) do if info := LDtkDoc_FieldInfo(c.doc, f); info.type == .Enum && info.enumUid == enumUid do n += 1
	return n
}

// External enum files (EditEnumDefs' import and its sources): each file's sync and removal, an import
@(private="file")
defsExternalEnums :: proc(c: ^LDtkTabCtx) {
	main := c.main
	tabHeading(c, "External enums")
	files := make([dynamic]string, context.temp_allocator)
	for d in Json_Items(main, LDtkDoc_Defs(c.doc, "externalEnums")) {
		rel := Json_String(main, Json_Get(main, d, "externalRelPath"))
		if !slice.contains(files[:], rel) do append(&files, rel)
	}
	for rel, i in files {
		full := joinPath(LDtkDoc_Folder(c.doc), rel, allocator = context.temp_allocator)
		state := "up to date"
		text, ok := readFileText(full)
		if !ok {
			state = "file not found"
		} else {
			for d in Json_Items(main, LDtkDoc_Defs(c.doc, "externalEnums")) {
				if Json_String(main, Json_Get(main, d, "externalRelPath")) == rel && Json_String(main, Json_Get(main, d, "externalFileChecksum")) != LDtk_Checksum(text) do state = "the file changed: sync it"
			}
		}
		tabNote(c, fmt.tprintf("%s: %s", rel, state), state != "up to date")
		sync := tabBase(c, .Enum_Sync)
		sync.text = strings.clone(rel, context.temp_allocator)
		unlink := tabBase(c, .Enum_External_Removed)
		unlink.text = sync.text
		label := "Sync"
		if state != "up to date" && ok {
			preview := LDtkEnums_SyncPreview(c.doc, rel)
			if preview.problem == "" do label = fmt.tprintf("Sync (+%d, -%d%s)", preview.added, preview.removed, preview.removedUsed > 0 ? fmt.tprintf(", %d used", preview.removedUsed) : "")
		}
		buttonRow(c, smallButton(c, fmt.tprintf("ldtk-enums-sync-%d", i), fmt.tprintf("%s  %s", ICON_REFRESH, label), Msg(sync), disabled = !ok),
			smallButton(c, fmt.tprintf("ldtk-enums-unlink-%d", i), fmt.tprintf("%s  Remove its enums", ICON_TRASH), Msg(unlink)))
	}
	// Importable files: the project's text, JSON, Haxe and CastleDB files beside the LDtk project
	labels := make([dynamic]string, context.temp_allocator)
	values := make([dynamic]string, context.temp_allocator)
	for path in LDtkDefs_EnumFiles(c.s, c.doc) {
		if slice.contains(files[:], path) do continue
		append(&labels, path)
		append(&values, path)
	}
	if len(labels) == 0 {
		tabNote(c, "Import enums from a text file (\"MyEnum: a, b, c\" a line), JSON, Haxe source or a CastleDB file: put one in the project's assets.")
		return
	}
	imp := tabBase(c, .Enum_Import)
	tabRow(c, "Import", tabChoiceField(c, "ldtk-enums-import", "Import enums from...", labels[:], values[:], imp), "Enums from a file, kept in step with it (LDtk's external enums: their values are the file's)")
}

// A file's text (false when it can't be read)
@(private="file")
readFileText :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", false
	return string(data), true
}

// The project's files under assets/ with one of the extensions, relative to the project (temp)
@(private="file")
assetFilesWith :: proc(root: string, exts: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	walk :: proc(out: ^[dynamic]string, root, rel: string, exts: []string, depth: int) {
		if depth > 8 do return
		entries, err := os.read_all_directory_by_path(joinPath(root, rel, allocator = context.temp_allocator), context.temp_allocator)
		if err != nil do return
		for entry in entries {
			path := rel == "" ? strings.clone(entry.name, context.temp_allocator) : fmt.tprintf("%s/%s", rel, entry.name)
			if entry.type == .Directory {
				walk(out, root, path, exts, depth + 1)
				continue
			}
			ext := strings.to_lower(filepath.ext(entry.name), context.temp_allocator)
			if slice.contains(exts, ext) do append(out, path)
		}
	}
	walk(&out, root, "assets", exts, 0)
	slice.sort(out[:])
	return out[:]
}

/*
The files enums can be imported from: the project's assets with LDtk's enum extensions (.txt,
.json, .hx, .cdb), relative to the .ldtk file.
*/
LDtkDefs_EnumFiles :: proc(s: ^State, doc: ^LDtkDoc) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for path in assetFilesWith(s.project.rootPath, {".txt", ".json", ".hx", ".cdb"}) {
		if rel, ok := LDtk_RelativePath(LDtkDoc_Folder(doc), joinPath(s.project.rootPath, path, allocator = context.temp_allocator)); ok do append(&out, rel)
	}
	return out[:]
}

// --- Tilesets --------------------------------------------------------------------------------

/*
The Tilesets tab (EditTilesetDefs): new ones from the project's images (or without one, or LDtk's
icons), the list's buttons, the selected one's name, image, grid, spacing, padding, tags and tag
enum, and its tiles' data on its picture: an enum value's tags (drag to tag, the right button
untags) or a tile's custom data.
*/
LDtkDefs_Tilesets :: proc(c: ^LDtkTabCtx) {
	tk := uiTokens(c.ctx)
	main := c.main
	th := c.ctx.theme
	images := LDtkDefs_Images(c.s, c.doc)
	imageLabels := make([dynamic]string, context.temp_allocator)
	imageValues := make([dynamic]string, context.temp_allocator)
	for path in images {
		append(&imageLabels, filepath.base(path))
		append(&imageValues, path)
	}
	add := tabBase(c, .Def_Added)
	add.kind = .Tileset
	empty, icons := add, add
	icons.text = "LdtkIcons"
	hasIcons := false
	for td in Json_Items(main, LDtkDoc_Defs(c.doc, "tilesets")) do if Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do hasIcons = true
	// The toolbar row: a new tileset (of an image, without one, LDtk's icons), then the list's buttons
	newTileset := labeledSelect(c.ctx, "", imageLabels[:], imageValues[:], add, proc(edit: LDtk_Edit, v: string) -> Msg {
		e := edit
		e.text = v
		return e
	}, id = skald.hash_id("ldtk-tilesets-add"), width = tk.fieldM, placeholder = fmt.tprintf("%s From an image...", ICON_PLUS))
	tabToolView(c, skald.tooltip(c.ctx, newTileset, "A tileset of one of the project's images (LDtk takes a file beside the project)", id = skald.hash_id("ldtk-tilesets-add-tip")))
	tabTool(c, "ldtk-tilesets-add-empty", ICON_PLUS, "A tileset without an image (pick one later)", Msg(empty), label = "Empty")
	tabTool(c, "ldtk-tilesets-add-icons", ICON_PLUS, "LDtk's internal icons as a tileset (one per project)", Msg(icons), label = "LDtk icons", disabled = hasIcons)
	c.list.empty = "No tilesets: add one from an image."
	sets := LDtkDoc_Defs(c.doc, "tilesets")
	if Json_Count(main, sets) == 0 {
		tabNote(c, "No tilesets yet.")
		return
	}
	def := -1
	for d in Json_Items(main, sets) {
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		if def < 0 || uid == c.s.level.tilesetDef do def = d
	}
	for d in Json_Items(main, sets) {
		row := ColoredTreeRow{label = strings.clone(Json_String(main, Json_Get(main, d, "identifier")), context.temp_allocator), icon = ICON_IMAGE, iconColor = AssetKind_Color(.Image), selected = d == def}
		tabListItem(c, row, Msg(LDtk_Def_Picked{what = .Tileset, uid = Json_Int(main, Json_Get(main, d, "uid"))}))
	}
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	items := Json_Items(main, sets)
	at, _ := slice.linear_search(items, def)
	e := tabBase(c, .Def_Removed)
	e.kind, e.def = .Tileset, uid
	embed := Json_String(main, Json_Get(main, def, "embedAtlas")) == "LdtkIcons"
	listTools(c, "tilesets", "tileset", e, at, len(items))
	c.list.text = fmt.tprintf("%s: %d of %d", Json_String(main, Json_Get(main, def, "identifier")), at + 1, len(items))
	if embed {
		tabNote(c, "LDtk's internal icons (by FinalBossBlues, finalbossblues.itch.io/icons): for the editor only. A game shows them when the project has its own copy of finalbossblues-icons_full_16.png beside the .ldtk file (they're licensed from their author).")
	} else {
		memberText(c, "Name", "The tileset's identifier (it follows its image's name while it's the default)", .Tileset, uid, "identifier", Json_String(main, Json_Get(main, def, "identifier")))
		rel := Json_String(main, Json_Get(main, def, "relPath"))
		labels := make([dynamic]string, context.temp_allocator)
		values := make([dynamic]string, context.temp_allocator)
		append(&labels, "No image")
		append(&values, "")
		append(&labels, ..imageLabels[:])
		append(&values, ..imageValues[:])
		memberChoice(c, "Image", "The tileset's picture: another one keeps tiles by their column and row", .Tileset, uid, "relPath", rel == "" ? "No image" : rel, labels[:], values[:])
	}
	tabNote(c, fmt.tprintf("%d x %d px, %d x %d tiles", Json_Int(main, Json_Get(main, def, "pxWid")), Json_Int(main, Json_Get(main, def, "pxHei")), Json_Int(main, Json_Get(main, def, "__cWid")), Json_Int(main, Json_Get(main, def, "__cHei"))))
	limit := f64(tilesetMaxGrid(main, def))
	memberNumber(c, "Grid", "The tiles' size in pixels: changing it keeps every placed tile at its column and row", .Tileset, uid, "tileGridSize", Json_Float(main, Json_Get(main, def, "tileGridSize"), 16), 1, 0, 2, limit)
	memberNumber(c, "Spacing", "Pixels between tiles", .Tileset, uid, "spacing", Json_Float(main, Json_Get(main, def, "spacing")), 1, 0, 0, limit)
	memberNumber(c, "Padding", "Pixels around the tiles at the image's edges", .Tileset, uid, "padding", Json_Float(main, Json_Get(main, def, "padding")), 1, 0, 0, limit)
	memberText(c, "Tags", "Tags of the tileset, separated by commas (LDtk groups its lists by them)", .Tileset, uid, "tags", tagsText(main, Json_Get(main, def, "tags")))
	enumLabels, enumValues := defChoices(c, LDtkDoc_Defs(c.doc, "enums"), "None")
	source := uidText(main, Json_Get(main, def, "tagsSourceEnumUid"))
	memberChoice(c, "Tag enum", "An enum whose values tag tiles (LDtk's tile tags: games read which tiles have which); another one drops the tags it doesn't have", .Tileset, uid, "tagsSourceEnumUid", labelOf(enumLabels, enumValues, source), enumLabels, enumValues)

	// The tiles' data on the picture
	tabHeading(c, "Tiles")
	modeLabels := make([dynamic]string, context.temp_allocator)
	modeValues := make([dynamic]string, context.temp_allocator)
	append(&modeLabels, "Custom data")
	append(&modeValues, "")
	source_ := -1
	if source != "" do source_, _ = strconv.parse_int(source)
	enumValuesList := source_ >= 0 ? LDtkDoc_EnumValues(c.doc, source_) : nil
	for v in enumValuesList {
		append(&modeLabels, fmt.tprintf("Tag %s", v))
		append(&modeValues, v)
	}
	mode := c.s.level.tileTag
	if mode != "" && !slice.contains(enumValuesList, mode) do mode = ""
	Mode :: struct {}
	tabRow(c, "Tile data", labeledSelect(c.ctx, labelOf(modeLabels[:], modeValues[:], mode), modeLabels[:], modeValues[:], Mode{}, proc(_: Mode, v: string) -> Msg {
		return LDtk_Def_Picked{what = .Tile_Tag, text = v}
	}, id = skald.hash_id("ldtk-tileset-mode"), width = c.controlWidth), "What a click on the tiles does: pick a tile for its custom data, or tag tiles with an enum value (drag; the right button untags)")
	if mode == "" {
		marked := make([dynamic]int, context.temp_allocator)
		data := ""
		for d in Json_Items(main, Json_Get(main, def, "customData")) {
			id := Json_Int(main, Json_Get(main, d, "tileId"))
			append(&marked, id)
			if id == c.s.level.dataTile do data = Json_String(main, Json_Get(main, d, "data"))
		}
		append(c.rows, tilesetPicker(c, "tileset", uid, nil, {}, mode = .Tile, tagged = c.s.level.dataTile >= 0 ? []int{c.s.level.dataTile} : nil, tagColor = 0x44AAFF, marked = marked[:]))
		if c.s.level.dataTile >= 0 {
			edit := tabBase(c, .Tileset_Custom_Data)
			edit.def = uid
			ids := make([]int, 1, context.temp_allocator)
			ids[0] = c.s.level.dataTile
			edit.ids = ids
			tabRow(c, fmt.tprintf("Tile %d data", c.s.level.dataTile), tabTextField(c, "ldtk-tileset-data", data, edit), "Any text the game reads with the tile (JSON, numbers...): empty removes it")
		} else {
			tabNote(c, "Click a tile to give it custom data (tiles with data are outlined).")
		}
	} else {
		tagged := make([dynamic]int, context.temp_allocator)
		for entry in Json_Items(main, Json_Get(main, def, "enumTags")) {
			if Json_String(main, Json_Get(main, entry, "enumValueId")) != mode do continue
			for id in Json_Items(main, Json_Get(main, entry, "tileIds")) do append(&tagged, Json_Int(main, id))
		}
		color := u32(0xFFCC00)
		if _, v := enumValue(c.doc, source_, mode); v >= 0 do color = u32(Json_Int(main, Json_Get(main, v, "color")))
		edit := tabBase(c, .Tileset_Tag)
		edit.def = uid
		edit.text = strings.clone(mode, context.temp_allocator)
		append(c.rows, tilesetPicker(c, "tileset", uid, nil, edit, mode = .Tags, tagged = tagged[:], tagColor = color))
		tabNote(c, fmt.tprintf("%d tile%s tagged %s: drag over tiles to tag them, with the right button to untag.", len(tagged), len(tagged) == 1 ? "" : "s", mode))
	}
	_ = th
}

/*
The images a tileset can take: the project's image assets, as paths relative to the .ldtk file
(LDtk keeps its images' paths relative to the project file).
*/
LDtkDefs_Images :: proc(s: ^State, doc: ^LDtkDoc) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for a in s.project.assets {
		if a.kind != .Image do continue
		if rel, ok := LDtkDefs_ImagePath(s.project.rootPath, doc, a.path); ok do append(&out, rel)
	}
	return out[:]
}
