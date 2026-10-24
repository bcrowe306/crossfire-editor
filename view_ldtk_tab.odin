package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Level mode's LDtk tab (the bottom panel's): a sidebar of vertical tabs (`LDtkTab`: Layers,
Entities, Collisions, Links, Level fields, Enums, World, Tilesets) and the shown section's
settings beside it, for the Level mode's LDtk project and its selected level. Every control sends
an `LDtk_Edit` (ldtk_ops.odin), written into the files at once, one undo step each; what isn't
editable here yet says so. Text fields keep what's typed while they have focus (State.numberEdit)
and write it whenever it's a valid value; why the last edit wasn't written shows above the
section (`LevelMode.problem`).

Widget keys: the tabs `ldtk-tab-<Tab>`, the section's scroll `ldtk-tab-scroll`, its item choice
`ldtk-item-<Tab>`; Layers: `ldtk-layer-name`, `-opacity`, `-parallax-x`, `-parallax-y`,
`-parallax-scaling`, `-grid`, `-visible`, `-up`, `-down`; Entities: `ldtk-entity-name`, `-width`,
`-height`, `-color`, `-pivot-x`, `-pivot-y`, fields `ldtk-field-name-<uid>`,
`ldtk-field-default-<uid>`, instances `ldtk-instance-<i>`, the selected one's `ldtk-instance-x`,
`-y`, `ldtk-instance-field-<uid>`; Collisions: `ldtk-intgrid-name-<value>`, `-color-<value>`,
`ldtk-kind-<value>-<scene>-<node>`; Links: `ldtk-ref-<i>-<uid>` (the i-th entity's field);
Level fields: `ldtk-level-field-<uid>`, `ldtk-level-field-name-<uid>`; Enums:
`ldtk-enum-name`, `ldtk-enum-value-<i>`, `ldtk-enum-color-<i>`, `ldtk-enum-new-value`,
`ldtk-enum-add-value`, `ldtk-enum-new`, `ldtk-enum-add`; World: `ldtk-world-layout`,
`ldtk-world-grid-w`, `-grid-h`, `ldtk-world-x-<i>`, `ldtk-world-y-<i>`.
*/

// The tabs' names in the sidebar
LDTK_TAB_NAMES := [LDtkTab]string{
	.Layers = "Layers", .Entities = "Entities", .Collisions = "Collisions", .Links = "Links",
	.Level_Fields = "Level fields", .Enums = "Enums", .World = "World", .Tilesets = "Tilesets",
}

// Under this panel width the sections are a choice (`ldtk-tab-select`) over the content
LDTK_TAB_COMPACT_WIDTH :: 380

// The sidebar's width, and the labels' column
@(private="file")
LDTK_TAB_SIDEBAR :: 104
@(private="file")
LDTK_LABEL_WIDTH :: 96

// What a section builds with: the document, the edit every control starts from, widths
@(private="file")
LDtkTabCtx :: struct {
	s: ^State,
	ctx: ^skald.Ctx(Msg),
	doc: ^LDtkDoc,
	main: ^JsonDoc,
	// The project-relative .ldtk path (temp)
	file: string,
	// The selected level (-1 none) and its iid (temp)
	level: int,
	levelIid: string,
	controlWidth, rowWidth: f32,
	// Rows stack their labels over their controls (a narrow panel)
	stacked: bool,
	rows: ^[dynamic]skald.View,
}

/*
The bottom panel's LDtk tab: the vertical tabs and the shown section, for the Level mode's file
(view_bottom.odin builds it).
*/
LevelMode_LDtkTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	if doc == nil do return placeholder(ctx, "The LDtk tab edits the world's LDtk project: import an .ldtk file first.")
	if doc.problem != "" do return placeholder(ctx, fmt.tprintf("%s can't be read as an LDtk project: %s", filepath.base(file), doc.problem))

	// The panel's width: the Level mode's center column. Narrow (a tiled window's), the sections
	// are a choice over the content, which keeps the whole width
	layout := Mode_LayoutOf(s, .Level)
	left, right := FittedSidebarWidths(layout)
	panel := max(layout.workspace.x - left - right - DIVIDER * 2, MIN_CENTER_WIDTH)
	compact := panel < LDTK_TAB_COMPACT_WIDTH
	tabs := make([dynamic]skald.View, context.temp_allocator)
	if !compact do for name, tab in LDTK_TAB_NAMES {
		active := tab == s.level.tab
		append(&tabs, skald.button(ctx, name, Msg(LDtk_Tab_Picked(tab)), id = skald.hash_id(fmt.tprintf("ldtk-tab-%v", tab)),
			bg = active ? th.color.primary : th.color.surface, fg = active ? th.color.on_primary : th.color.fg,
			padding = {th.spacing.sm, 3}, font_size = th.font.size_xs, radius = th.radius.sm, width = LDTK_TAB_SIDEBAR - th.spacing.sm * 2))
	}
	sidebar := skald.scroll(ctx, {0, 0}, skald.col(..tabs[:], spacing = 2, padding = th.spacing.xs), id = skald.hash_id("ldtk-tab-sidebar"))

	content := max(panel - (compact ? 0 : LDTK_TAB_SIDEBAR) - th.spacing.sm * 2 - 16, 120)
	stacked := content < LDTK_LABEL_WIDTH + 140
	control := stacked ? min(content, 260) : min(content - LDTK_LABEL_WIDTH - th.spacing.sm, 260)

	rows := make([dynamic]skald.View, context.temp_allocator)
	level := s.level.level != "" ? LDtkDoc_FindLevel(doc, s.level.level) : -1
	levelIid := ""
	if level >= 0 do _, levelIid = LDtkDoc_LevelNames(doc, level)
	c := LDtkTabCtx{s = s, ctx = ctx, doc = doc, main = LDtkDoc_Main(doc), file = strings.clone(file, context.temp_allocator), level = level,
		levelIid = strings.clone(levelIid, context.temp_allocator), controlWidth = control, rowWidth = content, stacked = stacked, rows = &rows}
	if compact {
		names := make([dynamic]string, context.temp_allocator)
		for name in LDTK_TAB_NAMES do append(&names, name)
		append(&rows, skald.select(ctx, LDTK_TAB_NAMES[s.level.tab], names[:], proc(name: string) -> Msg {
			for n, tab in LDTK_TAB_NAMES do if n == name do return LDtk_Tab_Picked(tab)
			return LDtk_Tab_Picked(LDtkTab.Layers)
		}, id = skald.hash_id("ldtk-tab-select"), width = content))
	}
	if s.level.problem != "" do append(&rows, skald.text(fmt.tprintf("Not saved: %s", s.level.problem), th.color.warning, th.font.size_xs, max_width = content))
	if old := LDtkOps_TooOld(doc); old != "" do append(&rows, skald.text(fmt.tprintf("Read only: %s", old), th.color.warning, th.font.size_xs, max_width = content))
	switch s.level.tab {
	case .Layers:       ldtkLayersSection(&c)
	case .Entities:     ldtkEntitiesSection(&c)
	case .Collisions:   ldtkCollisionsSection(&c)
	case .Links:        ldtkLinksSection(&c)
	case .Level_Fields: ldtkLevelFieldsSection(&c)
	case .Enums:        ldtkEnumsSection(&c)
	case .World:        ldtkWorldSection(&c)
	case .Tilesets:     ldtkTilesetsSection(&c)
	}
	body := skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("ldtk-tab-scroll"))
	if compact do return body
	return skald.row(
		skald.col(skald.flex(1, sidebar), width = LDTK_TAB_SIDEBAR, cross_align = .Stretch),
		skald.flex(1, body),
		spacing = 0,
		cross_align = .Stretch,
	)
}

// The base edit of the tab's controls (the file; temp strings)
@(private="file")
base :: proc(c: ^LDtkTabCtx, op: LDtkEditOp) -> LDtk_Edit {
	return {op = op, file = c.file, level = c.levelIid}
}

// A row: a label (with its tooltip) beside its control, or over it in a narrow panel
@(private="file")
row :: proc(c: ^LDtkTabCtx, label: string, control: skald.View, tip: string) {
	ctx := c.ctx
	th := ctx.theme
	text := skald.text(label, th.color.fg_muted, th.font.size_sm)
	rowTipCount += 1
	labelView := skald.tooltip(ctx, text, tip, id = skald.hash_id(fmt.tprintf("row-tip-%d", rowTipCount)))
	if c.stacked {
		append(c.rows, skald.col(labelView, control, spacing = 2))
		return
	}
	append(c.rows, skald.row(skald.col(labelView, width = LDTK_LABEL_WIDTH), control, spacing = th.spacing.sm, cross_align = .Center))
}

// A heading inside a section
@(private="file")
heading :: proc(c: ^LDtkTabCtx, text: string) {
	th := c.ctx.theme
	append(c.rows, skald.spacer(th.spacing.xs), skald.text(text, th.color.fg, th.font.size_sm, max_width = c.rowWidth))
}

// A note (`warning`: something not editable here, or a problem)
@(private="file")
note :: proc(c: ^LDtkTabCtx, text: string, warning := false) {
	th := c.ctx.theme
	append(c.rows, skald.text(text, warning ? th.color.warning : th.color.fg_muted, th.font.size_xs, max_width = c.rowWidth))
}

// A text field: what's typed is kept while it has focus, sent with the edit (`edit.text`)
@(private="file")
textField :: proc(c: ^LDtkTabCtx, key, value: string, edit: LDtk_Edit, width: f32 = 0) -> skald.View {
	ctx := c.ctx
	s := c.s
	id := skald.hash_id(key)
	focused := skald.widget_has_focus(ctx, id)
	editing := s.numberEdit.id == id
	if editing && !focused do skald.send(ctx, Msg(Number_Edit_Ended(id)))
	text := editing && focused ? strings.clone(s.numberEdit.text, context.temp_allocator) : strings.clone(value, context.temp_allocator)
	Payload :: struct {
		edit: LDtk_Edit,
		id: skald.Widget_ID,
	}
	return skald.text_input(ctx, text, Payload{edit, id}, proc(p: Payload, v: string) -> Msg {
		edit := p.edit
		edit.text = v
		return LDtk_Text_Typed{p.id, edit}
	}, id = id, width = width > 0 ? width : c.controlWidth, padding = {ctx.theme.spacing.sm, 2})
}

// A number field (−/+ step it)
@(private="file")
numberRow :: proc(c: ^LDtkTabCtx, label, key, tip: string, edit: LDtk_Edit, value, step: f64, decimals: int, lo, hi: f64) {
	row(c, label, numberField(c.ctx, c.s, key, LDtkNumberTarget{edit}, value, step, decimals, min(c.controlWidth, 160), lo, hi), tip)
}

// A checkbox sending the edit with `flag`
@(private="file")
flagRow :: proc(c: ^LDtkTabCtx, label, key, tip: string, edit: LDtk_Edit, value: bool) {
	box := skald.checkbox(c.ctx, value, "", edit, proc(edit: LDtk_Edit, v: bool) -> Msg {
		e := edit
		e.flag = v
		return e
	}, id = skald.hash_id(key))
	row(c, label, box, tip)
}

// A color: its swatch and its #RRGGBB text field
@(private="file")
colorField :: proc(c: ^LDtkTabCtx, key, value: string, edit: LDtk_Edit) -> skald.View {
	color := skald.rgb(0x000000)
	if v, ok := LDtk_ParseColor(value); ok do color = skald.rgb(u32(v))
	swatch := skald.col(skald.spacer(0), width = 16, height = 16, bg = color, radius = 2)
	return skald.row(swatch, textField(c, key, value, edit, max(c.controlWidth - 22, 60)), spacing = 6, cross_align = .Center)
}

// A select of labels sending `values[i]` as the edit's text
@(private="file")
choiceField :: proc(c: ^LDtkTabCtx, key, shown: string, labels, values: []string, edit: LDtk_Edit) -> skald.View {
	return labeledSelect(c.ctx, shown, labels, values, edit, proc(edit: LDtk_Edit, v: string) -> Msg {
		e := edit
		e.text = v
		return e
	}, id = skald.hash_id(key), width = c.controlWidth)
}

// The section's item choice: definitions by name, the selected one's uid (the first when it's gone)
@(private="file")
itemChoice :: proc(c: ^LDtkTabCtx, tab: LDtkTab, list: int, selected: int, label: string, filter: proc(json: ^JsonDoc, node: int) -> bool = nil) -> int {
	main := c.main
	names := make([dynamic]string, context.temp_allocator)
	uids := make([dynamic]string, context.temp_allocator)
	// The selected one, else the first
	chosen := -1
	shown := ""
	for d in Json_Items(main, list) {
		if filter != nil && !filter(main, d) do continue
		uid := Json_Int(main, Json_Get(main, d, "uid"), -1)
		name := Json_String(main, Json_Get(main, d, "identifier"))
		if t := Json_String(main, Json_Get(main, d, "__type")); t != "" do name = fmt.tprintf("%s (%s)", name, t)
		append(&names, name)
		append(&uids, fmt.tprint(uid))
		if chosen < 0 || uid == selected do chosen, shown = d, name
		if uid == selected do break
	}
	// The rest of the list, after the selected one
	if chosen >= 0 do for d in Json_Items(main, list)[len(names):] {
		if filter != nil && !filter(main, d) do continue
		name := Json_String(main, Json_Get(main, d, "identifier"))
		if t := Json_String(main, Json_Get(main, d, "__type")); t != "" do name = fmt.tprintf("%s (%s)", name, t)
		append(&names, name)
		append(&uids, fmt.tprint(Json_Int(main, Json_Get(main, d, "uid"), -1)))
	}
	if len(names) == 0 do return -1
	Pick :: struct { tab: LDtkTab }
	picker := labeledSelect(c.ctx, shown, names[:], uids[:], Pick{tab}, proc(p: Pick, v: string) -> Msg {
		uid, _ := strconvParseInt(v)
		return LDtk_Item_Picked{p.tab, uid}
	}, id = skald.hash_id(fmt.tprintf("ldtk-item-%v", tab)), width = c.controlWidth)
	row(c, label, picker, "Which one the section shows")
	return chosen
}

@(private="file")
strconvParseInt :: proc(text: string) -> (int, bool) {
	n := 0
	neg := strings.has_prefix(text, "-")
	t := strings.trim_prefix(text, "-")
	if t == "" do return 0, false
	for ch in t {
		if ch < '0' || ch > '9' do return 0, false
		n = n * 10 + int(ch - '0')
	}
	return neg ? -n : n, true
}

// A JSON value as a field's text: strings unquoted, null empty
@(private="file")
valueText :: proc(json: ^JsonDoc, node: int) -> string {
	#partial switch Json_Kind(json, node) {
	case .String: return Json_String(json, node)
	case .Null: return ""
	case .Object:
		// Points: "cx, cy"; references: the target's iid
		if cx := Json_Get(json, node, "cx"); cx >= 0 do return fmt.tprintf("%d, %d", Json_Int(json, cx), Json_Int(json, Json_Get(json, node, "cy")))
		if iid := Json_Get(json, node, "entityIid"); iid >= 0 do return Json_String(json, iid)
	}
	return Json_Text(json, node)
}

// Layers: the definition's settings, the selected level's visibility, the order
@(private="file")
ldtkLayersSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	note(c, "Each layer of the project, top-most first (as LDtk lists them). Changes apply to every level.")
	def := itemChoice(c, .Layers, LDtkDoc_Defs(c.doc, "layers"), c.s.level.layerDef, "Layer")
	if def < 0 {
		note(c, "This project has no layers.")
		return
	}
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	edit :: proc(c: ^LDtkTabCtx, op: LDtkEditOp, uid: int) -> LDtk_Edit { e := base(c, op); e.def = uid; return e }
	row(c, "Name", textField(c, "ldtk-layer-name", Json_String(main, Json_Get(main, def, "identifier")), edit(c, .Layer_Name, uid)), "The layer's identifier: games and LDtkLevel nodes find it by name (scenes naming it follow a rename)")
	kind := Json_String(main, Json_Get(main, def, "__type"))
	if Json_Count(main, Json_Get(main, def, "autoRuleGroups")) > 0 do kind = fmt.tprintf("%s with auto-layer rules", kind)
	row(c, "Type", skald.text(kind, c.ctx.theme.color.fg, c.ctx.theme.font.size_sm), "What the layer holds (not editable: LDtk converts layers)")
	if c.level >= 0 {
		file, array := LDtkDoc_LayerInstances(c.doc, c.level)
		json := LDtkDoc_Json(c.doc, file)
		for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == uid {
			flagRow(c, fmt.tprintf("Shown in %s", c.s.level.level), "ldtk-layer-visible", "Whether this level shows the layer (LDtk's eye; the engine skips hidden layers)", edit(c, .Layer_Visible, uid), Json_Bool(json, Json_Get(json, li, "visible"), true))
		}
	} else {
		note(c, "Select a level on the canvas to show or hide the layer in it.")
	}
	numberRow(c, "Opacity", "ldtk-layer-opacity", "How opaque the layer draws, 0 to 1", edit(c, .Layer_Opacity, uid), Json_Float(main, Json_Get(main, def, "displayOpacity"), 1), 0.05, 2, 0, 1)
	numberRow(c, "Parallax X", "ldtk-layer-parallax-x", "How much slower (positive) or faster (negative) the layer scrolls sideways, -1 to 1", edit(c, .Layer_Parallax_X, uid), Json_Float(main, Json_Get(main, def, "parallaxFactorX")), 0.05, 2, -1, 1)
	numberRow(c, "Parallax Y", "ldtk-layer-parallax-y", "The same up and down, -1 to 1", edit(c, .Layer_Parallax_Y, uid), Json_Float(main, Json_Get(main, def, "parallaxFactorY")), 0.05, 2, -1, 1)
	flagRow(c, "Parallax scaling", "ldtk-layer-parallax-scaling", "Whether a parallax layer also scales with its factor", edit(c, .Layer_Parallax_Scaling, uid), Json_Bool(main, Json_Get(main, def, "parallaxScaling"), true))
	grid := Json_Int(main, Json_Get(main, def, "gridSize"), 16)
	if why := LDtkOps_GridSizeLocked(c.doc, uid); why != "" {
		row(c, "Grid size", skald.text(fmt.tprintf("%d px", grid), c.ctx.theme.color.fg, c.ctx.theme.font.size_sm), "The layer's cell size in pixels")
		note(c, fmt.tprintf("Not editable here: %s.", why), true)
	} else {
		numberRow(c, "Grid size", "ldtk-layer-grid", "The layer's cell size in pixels", edit(c, .Layer_Grid_Size, uid), f64(grid), 1, 0, 1, 1024)
	}
	items := Json_Items(main, LDtkDoc_Defs(c.doc, "layers"))
	at, _ := slice.linear_search(items, def)
	th := c.ctx.theme
	up := edit(c, .Layer_Move, uid)
	up.number = -1
	down := up
	down.number = 1
	buttons := skald.row(
		skald.button(c.ctx, fmt.tprintf("%s  Up", ICON_ARROW_UP), Msg(up), id = skald.hash_id("ldtk-layer-up"), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = at <= 0),
		skald.button(c.ctx, fmt.tprintf("%s  Down", ICON_ARROW_DOWN), Msg(down), id = skald.hash_id("ldtk-layer-down"), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = at >= len(items) - 1),
		skald.text(fmt.tprintf("%d of %d, top first", at + 1, len(items)), th.color.fg_muted, th.font.size_xs),
		spacing = th.spacing.xs, cross_align = .Center,
	)
	row(c, "Order", buttons, "Where the layer is in the list: higher draws over lower")
}

// Entities: the type's settings, its fields' definitions, its instances in the selected level
@(private="file")
ldtkEntitiesSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	th := c.ctx.theme
	def := itemChoice(c, .Entities, LDtkDoc_Defs(c.doc, "entities"), c.s.level.entityDef, "Entity type")
	if def < 0 {
		note(c, "This project has no entity types: add them in LDtk.")
		return
	}
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	edit :: proc(c: ^LDtkTabCtx, op: LDtkEditOp, uid: int) -> LDtk_Edit { e := base(c, op); e.def = uid; return e }
	row(c, "Name", textField(c, "ldtk-entity-name", Json_String(main, Json_Get(main, def, "identifier")), edit(c, .Entity_Name, uid)), "The entity type's identifier: scripts named like it run on its entities (scenes' rules follow a rename; code doesn't)")
	numberRow(c, "Width", "ldtk-entity-width", "The type's width in pixels (entities not resized in LDtk follow it)", edit(c, .Entity_Width, uid), Json_Float(main, Json_Get(main, def, "width"), 16), 1, 0, 1, 4096)
	numberRow(c, "Height", "ldtk-entity-height", "The type's height in pixels", edit(c, .Entity_Height, uid), Json_Float(main, Json_Get(main, def, "height"), 16), 1, 0, 1, 4096)
	row(c, "Color", colorField(c, "ldtk-entity-color", Json_String(main, Json_Get(main, def, "color")), edit(c, .Entity_Color, uid)), "The type's color, #RRGGBB (its outline in LDtk and here)")
	numberRow(c, "Pivot X", "ldtk-entity-pivot-x", "Where the entity's position is across it: 0 left, 0.5 middle, 1 right", edit(c, .Entity_Pivot_X, uid), Json_Float(main, Json_Get(main, def, "pivotX"), 0.5), 0.5, 1, 0, 1)
	numberRow(c, "Pivot Y", "ldtk-entity-pivot-y", "Where it is up and down: 0 top, 0.5 middle, 1 bottom", edit(c, .Entity_Pivot_Y, uid), Json_Float(main, Json_Get(main, def, "pivotY"), 0.5), 0.5, 1, 0, 1)

	heading(c, "Fields")
	fields := Json_Items(main, Json_Get(main, def, "fieldDefs"))
	if len(fields) == 0 do note(c, "No fields: add them in LDtk.")
	for f in fields {
		info := LDtkDoc_FieldInfo(c.doc, f)
		e := base(c, .Field_Name)
		e.field = info.uid
		typeName, _ := strings.replace_all(Json_String(main, Json_Get(main, f, "__type")), "LocalEnum.", "", context.temp_allocator)
		row(c, fmt.tprintf("%s field", typeName), textField(c, fmt.tprintf("ldtk-field-name-%d", info.uid), info.identifier, e), "The field's identifier (its type is LDtk's: not editable here)")
		#partial switch info.type {
		case .Int, .Float, .Bool, .String, .Text:
			if !info.isArray {
				d := base(c, .Field_Default)
				d.field = info.uid
				row(c, "   Default", textField(c, fmt.tprintf("ldtk-field-default-%d", info.uid), ldtkDefaultShown(info), d), "The field's value when an entity has none of its own (empty: none)")
				continue
			}
		}
		shown := ldtkDefaultShown(info)
		note(c, fmt.tprintf("   Default: %s (edited in LDtk)", shown == "" ? "none" : shown))
	}

	heading(c, c.level >= 0 ? fmt.tprintf("In %s", c.s.level.level) : "Placed (every level)")
	shown := 0
	for en, i in LDtkDoc_Entities(c.doc) {
		json := LDtkDoc_Json(c.doc, en.file)
		if Json_Int(json, Json_Get(json, en.node, "defUid"), -1) != uid || (c.level >= 0 && en.level != c.level) do continue
		iid := Json_String(json, Json_Get(json, en.node, "iid"))
		px := Json_Get(json, en.node, "px")
		x, y := Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))
		levelName, _ := LDtkDoc_LevelNames(c.doc, en.level)
		selected := iid == c.s.level.entity
		label := fmt.tprintf("%s %s at %d, %d%s", selected ? ICON_CHEVRON_DOWN : ICON_ARROW_RIGHT, Json_String(json, Json_Get(json, en.node, "__identifier")), x, y, c.level < 0 ? fmt.tprintf(" (%s)", levelName) : "")
		append(c.rows, skald.button(c.ctx, label, Msg(Level_Entity_Picked(strings.clone(iid, context.temp_allocator))), id = skald.hash_id(fmt.tprintf("ldtk-instance-%d", i)),
			bg = selected ? th.color.primary : th.color.surface, fg = selected ? th.color.on_primary : th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
		shown += 1
		if !selected do continue
		move := base(c, .Entity_X)
		move.entity = strings.clone(iid, context.temp_allocator)
		numberRow(c, "X", "ldtk-instance-x", "Where the entity's pivot is in its level, pixels from the left", move, f64(x), 1, 0, -100000, 100000)
		move.op = .Entity_Y
		numberRow(c, "Y", "ldtk-instance-y", "Pixels from the top", move, f64(y), 1, 0, -100000, 100000)
		for fi in Json_Items(json, Json_Get(json, en.node, "fieldInstances")) {
			fieldUid := Json_Int(json, Json_Get(json, fi, "defUid"), -1)
			_, fieldDef := LDtkDoc_FieldDef(c.doc, fieldUid)
			if fieldDef < 0 do continue
			info := LDtkDoc_FieldInfo(c.doc, fieldDef)
			e := base(c, info.type == .EntityRef ? .Entity_Ref : .Entity_Field)
			e.entity = move.entity
			e.field = fieldUid
			fieldControl(c, info, json, fi, en, e, fmt.tprintf("ldtk-instance-field-%d", fieldUid))
		}
	}
	if shown == 0 do note(c, c.level >= 0 ? "None in this level." : "None placed.")
	note(c, "Click one to select it (on the canvas too, where a drag moves it).")
}

// A field's default as its field shows it (strings unquoted, none empty)
@(private="file")
ldtkDefaultShown :: proc(info: LDtkFieldInfo) -> string {
	if info.defaultText == "null" do return ""
	doc, problem := Json_Parse(info.defaultText, context.temp_allocator)
	if problem != "" do return info.defaultText
	return strings.clone(valueText(&doc, 0), context.temp_allocator)
}

/*
A field value's control by its type: a checkbox, an enum's or a reference's choice, else a text
field (empty: the default); arrays, tiles and symmetrical references say they aren't editable yet.
*/
@(private="file")
fieldControl :: proc(c: ^LDtkTabCtx, info: LDtkFieldInfo, json: ^JsonDoc, fi: int, owner: LDtkDocEntity, edit: LDtk_Edit, key: string) {
	value := Json_Get(json, fi, "__value")
	label := info.identifier
	tip := fmt.tprintf("The %s field %s (LDtk's type %s)", info.isArray ? "array" : "value", info.identifier, Json_String(json, Json_Get(json, fi, "__type")))
	why := LDtkOps_FieldLocked(info)
	if why == "" && edit.op == .Level_Field && info.type == .EntityRef do why = "a level's entity references aren't editable here yet (LDtk edits them)"
	if why != "" {
		row(c, label, skald.text(Json_Text(json, value), c.ctx.theme.color.fg, c.ctx.theme.font.size_xs, max_width = c.controlWidth), tip)
		note(c, fmt.tprintf("   %s", why), true)
		return
	}
	#partial switch info.type {
	case .Bool:
		e := edit
		box := skald.checkbox(c.ctx, Json_Bool(json, value), "", e, proc(edit: LDtk_Edit, v: bool) -> Msg {
			x := edit
			x.text = v ? "true" : "false"
			return x
		}, id = skald.hash_id(key))
		row(c, label, box, tip)
	case .Enum:
		values := LDtkDoc_EnumValues(c.doc, info.enumUid)
		labels := make([dynamic]string, context.temp_allocator)
		vals := make([dynamic]string, context.temp_allocator)
		append(&labels, "(default)")
		append(&vals, "")
		append(&labels, ..values)
		append(&vals, ..values)
		shown := valueText(json, value)
		row(c, label, choiceField(c, key, shown == "" ? "(default)" : shown, labels[:], vals[:], edit), tip)
	case .EntityRef:
		labels, vals := refChoices(c, info, owner)
		shown := "(none)"
		target := valueText(json, value)
		for v, i in vals do if v == target && target != "" do shown = labels[i]
		row(c, label, choiceField(c, key, shown, labels, vals, edit), tip)
	case:
		row(c, label, textField(c, key, valueText(json, value), edit), tip)
	}
}

// The entities a reference field of `owner` may point at: labels and iids, "(none)" first
@(private="file")
refChoices :: proc(c: ^LDtkTabCtx, info: LDtkFieldInfo, owner: LDtkDocEntity) -> (labels, values: []string) {
	ls := make([dynamic]string, context.temp_allocator)
	vs := make([dynamic]string, context.temp_allocator)
	append(&ls, "(none)")
	append(&vs, "")
	for target in LDtkDoc_Entities(c.doc) {
		if !LDtkOps_RefAllowed(c.doc, info, owner, target) do continue
		json := LDtkDoc_Json(c.doc, target.file)
		level, _ := LDtkDoc_LevelNames(c.doc, target.level)
		iid := Json_String(json, Json_Get(json, target.node, "iid"))
		append(&ls, fmt.tprintf("%s in %s (%s)", Json_String(json, Json_Get(json, target.node, "__identifier")), level, iid))
		append(&vs, iid)
	}
	return ls[:], vs[:]
}

// Collisions: an IntGrid layer's values (names, colors) and what LDtkLevel nodes make of them
@(private="file")
ldtkCollisionsSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	note(c, "IntGrid layers' values: their names and colors are LDtk's (saved into the file); what each becomes in a game (solid, one-way, an area) is the scene's LDtkLevel node's.")
	isIntGrid :: proc(json: ^JsonDoc, node: int) -> bool { return Json_String(json, Json_Get(json, node, "__type")) == "IntGrid" }
	def := itemChoice(c, .Collisions, LDtkDoc_Defs(c.doc, "layers"), c.s.level.intGridDef, "IntGrid layer", isIntGrid)
	if def < 0 {
		note(c, "This project has no IntGrid layers.")
		return
	}
	uid := Json_Int(main, Json_Get(main, def, "uid"))
	identifier := Json_String(main, Json_Get(main, def, "identifier"))
	values := Json_Items(main, Json_Get(main, def, "intGridValues"))
	for v in values {
		value := Json_Int(main, Json_Get(main, v, "value"))
		e := base(c, .IntGrid_Name)
		e.def, e.index = uid, value
		row(c, fmt.tprintf("Value %d", value), textField(c, fmt.tprintf("ldtk-intgrid-name-%d", value), Json_String(main, Json_Get(main, v, "identifier")), e), "The value's name (empty: none): games and Area nodes made from it use it")
		e.op = .IntGrid_Color
		row(c, "   Color", colorField(c, fmt.tprintf("ldtk-intgrid-color-%d", value), Json_String(main, Json_Get(main, v, "color")), e), "The value's color, #RRGGBB")
	}
	// The engine's collision kinds, per LDtkLevel node using this layer for collision
	found := false
	kinds := make([dynamic]string, context.temp_allocator)
	for label in LDTK_KIND_LABELS do append(&kinds, label)
	for &scene, si in c.s.project.scenes {
		if Scene_IsComponent(&scene) do continue
		for &node, ni in scene.nodes {
			if node.kind != .LDtkLevel || node.ldtk.file != c.file || node.ldtk.collisionLayer != identifier do continue
			found = true
			heading(c, fmt.tprintf("In %s, %s makes them:", scene.name, node.name))
			Kind :: struct { scene, node, value: int }
			for v in values {
				value := Json_Int(main, Json_Get(main, v, "value"))
				name := Json_String(main, Json_Get(main, v, "identifier"))
				choice := skald.select(c.ctx, LDTK_KIND_LABELS[e.LDtk_CollisionKind(&node.ldtk, value)], kinds[:], Kind{si, ni, value}, proc(k: Kind, label: string) -> Msg {
					kind := e.LDtkCollisionKind.None
					for l, kd in LDTK_KIND_LABELS do if l == label do kind = kd
					return Level_Collision_Kind_Changed{k.scene, k.node, k.value, kind}
				}, id = skald.hash_id(fmt.tprintf("ldtk-kind-%d-%d-%d", value, si, ni)), width = c.controlWidth)
				row(c, name != "" ? fmt.tprintf("%d %s", value, name) : fmt.tprintf("Value %d", value), choice, "What the LDtkLevel node makes of the value's cells")
			}
		}
	}
	if !found do note(c, fmt.tprintf("No scene's LDtkLevel node uses %s for collision yet: pick it in the node's inspector (Collision).", identifier))
}

// Links: entity references (retargeted here) and the levels' neighbours (from where they are)
@(private="file")
ldtkLinksSection :: proc(c: ^LDtkTabCtx) {
	heading(c, c.level >= 0 ? fmt.tprintf("References in %s", c.s.level.level) : "References (every level)")
	any := false
	for en, i in LDtkDoc_Entities(c.doc) {
		if c.level >= 0 && en.level != c.level do continue
		json := LDtkDoc_Json(c.doc, en.file)
		iid := Json_String(json, Json_Get(json, en.node, "iid"))
		for fi in Json_Items(json, Json_Get(json, en.node, "fieldInstances")) {
			t := Json_String(json, Json_Get(json, fi, "__type"))
			if t != "EntityRef" && t != "Array<EntityRef>" do continue
			_, fieldDef := LDtkDoc_FieldDef(c.doc, Json_Int(json, Json_Get(json, fi, "defUid"), -1))
			if fieldDef < 0 do continue
			info := LDtkDoc_FieldInfo(c.doc, fieldDef)
			any = true
			e := base(c, .Entity_Ref)
			e.entity = strings.clone(iid, context.temp_allocator)
			e.field = info.uid
			info.identifier = fmt.tprintf("%s.%s", Json_String(json, Json_Get(json, en.node, "__identifier")), info.identifier)
			fieldControl(c, info, json, fi, en, e, fmt.tprintf("ldtk-ref-%d-%d", i, info.uid))
		}
	}
	if !any do note(c, "No entity reference fields here.")
	heading(c, "Neighbours")
	if c.level < 0 {
		note(c, "Select a level to see its neighbours.")
		return
	}
	neighbours := LDtkDoc_Neighbours(c.doc, c.level)
	if len(neighbours) == 0 do note(c, "None: no level touches or overlaps this one.")
	dirName :: proc(dir: string) -> string {
		switch dir {
		case "n": return "north"
		case "s": return "south"
		case "e": return "east"
		case "w": return "west"
		case "ne": return "north-east"
		case "nw": return "north-west"
		case "se": return "south-east"
		case "sw": return "south-west"
		case "o": return "overlapping"
		case "<": return "overlapping, a depth below"
		case ">": return "overlapping, a depth above"
		}
		return dir
	}
	for n in neighbours {
		name := n.iid
		for _, i in c.doc.levels do if identifier, iid := LDtkDoc_LevelNames(c.doc, i); iid == n.iid do name = identifier
		note(c, fmt.tprintf("%s: %s", dirName(n.dir), name))
	}
	note(c, "LDtk works neighbours out from where the levels are: drag levels on the canvas (or set their places in World) to change them.")
}

// Level fields: the selected level's custom fields
@(private="file")
ldtkLevelFieldsSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	defs := Json_Items(main, LDtkDoc_Defs(c.doc, "levelFields"))
	if len(defs) == 0 {
		note(c, "This project's levels have no custom fields: add them in LDtk (Project settings > Level fields).")
		return
	}
	if c.level < 0 {
		note(c, "Select a level on the canvas to edit its fields.")
		for f in defs {
			info := LDtkDoc_FieldInfo(c.doc, f)
			e := base(c, .Field_Name)
			e.field = info.uid
			row(c, Json_String(main, Json_Get(main, f, "__type")), textField(c, fmt.tprintf("ldtk-level-field-name-%d", info.uid), info.identifier, e), "The level field's identifier")
		}
		return
	}
	heading(c, fmt.tprintf("%s's fields", c.s.level.level))
	entry := c.doc.levels[c.level].entry
	for fi in Json_Items(main, Json_Get(main, entry, "fieldInstances")) {
		uid := Json_Int(main, Json_Get(main, fi, "defUid"), -1)
		_, fieldDef := LDtkDoc_FieldDef(c.doc, uid)
		if fieldDef < 0 do continue
		info := LDtkDoc_FieldInfo(c.doc, fieldDef)
		e := base(c, .Level_Field)
		e.field = uid
		fieldControl(c, info, main, fi, {level = c.level}, e, fmt.tprintf("ldtk-level-field-%d", uid))
	}
	note(c, "Empty: the field's default. Games read them with e.LDtk_FieldValue.")
}

// Enums: their names, values and colors; new values and enums
@(private="file")
ldtkEnumsSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	th := c.ctx.theme
	def := itemChoice(c, .Enums, LDtkDoc_Defs(c.doc, "enums"), c.s.level.enumDef, "Enum")
	if def >= 0 {
		uid := Json_Int(main, Json_Get(main, def, "uid"))
		if Json_Kind(main, Json_Get(main, def, "externalRelPath")) == .String {
			note(c, fmt.tprintf("From the external file %s: edit it there (LDtk reads it again).", Json_String(main, Json_Get(main, def, "externalRelPath"))), true)
		} else {
			e := base(c, .Enum_Name)
			e.def = uid
			row(c, "Name", textField(c, "ldtk-enum-name", Json_String(main, Json_Get(main, def, "identifier")), e), "The enum's identifier (fields of it follow a rename)")
			for v, i in Json_Items(main, Json_Get(main, def, "values")) {
				e.op, e.index = .Enum_Value_Name, i
				row(c, fmt.tprintf("Value %d", i + 1), textField(c, fmt.tprintf("ldtk-enum-value-%d", i), Json_String(main, Json_Get(main, v, "id")), e), "The value's name: fields set to it follow a rename")
				e.op = .Enum_Value_Color
				row(c, "   Color", colorField(c, fmt.tprintf("ldtk-enum-color-%d", i), LDtk_FormatColor(Json_Int(main, Json_Get(main, v, "color"))), e), "The value's color, #RRGGBB")
			}
			add := base(c, .Enum_Value_Added)
			add.def = uid
			add.text = strings.clone(c.s.level.newValue, context.temp_allocator)
			row(c, "New value", skald.row(
				skald.text_input(c.ctx, strings.clone(c.s.level.newValue, context.temp_allocator), proc(v: string) -> Msg { return LDtk_New_Name_Typed{true, v} },
					id = skald.hash_id("ldtk-enum-new-value"), width = max(c.controlWidth - 60, 60), padding = {th.spacing.sm, 2}),
				skald.button(c.ctx, "Add", Msg(add), id = skald.hash_id("ldtk-enum-add-value"), bg = th.color.surface, fg = th.color.fg,
					padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = strings.trim_space(c.s.level.newValue) == ""),
				spacing = th.spacing.xs, cross_align = .Center), "A value to add to the enum")
		}
	} else {
		note(c, "This project has no enums yet.")
	}
	for d in Json_Items(main, LDtkDoc_Defs(c.doc, "externalEnums")) do note(c, fmt.tprintf("%s: an external enum (%s), edited in its file", Json_String(main, Json_Get(main, d, "identifier")), Json_String(main, Json_Get(main, d, "externalRelPath"))))
	heading(c, "New enum")
	add := base(c, .Enum_Added)
	add.text = strings.clone(c.s.level.newEnum, context.temp_allocator)
	row(c, "Name", skald.row(
		skald.text_input(c.ctx, strings.clone(c.s.level.newEnum, context.temp_allocator), proc(v: string) -> Msg { return LDtk_New_Name_Typed{false, v} },
			id = skald.hash_id("ldtk-enum-new"), width = max(c.controlWidth - 60, 60), padding = {th.spacing.sm, 2}),
		skald.button(c.ctx, "Add", Msg(add), id = skald.hash_id("ldtk-enum-add"), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = strings.trim_space(c.s.level.newEnum) == ""),
		spacing = th.spacing.xs, cross_align = .Center), "An enum to add to the project (its values added here after)")
}

// World: the layout, the grid, each level's place
@(private="file")
ldtkWorldSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	for world, wi in c.doc.worlds {
		identifier, _ := LDtkDoc_WorldNames(c.doc, wi)
		if len(c.doc.worlds) > 1 do heading(c, identifier)
		layout := LDtkDoc_WorldLayout(c.doc, wi)
		e := base(c, .World_Layout)
		e.world = wi
		layouts := []string{"Free", "GridVania", "LinearHorizontal", "LinearVertical"}
		labels := []string{"Free", "GridVania (on a grid)", "Linear, side by side", "Linear, one above the other"}
		row(c, "Layout", choiceField(c, len(c.doc.worlds) > 1 ? fmt.tprintf("ldtk-world-layout-%d", wi) : "ldtk-world-layout", layout, labels, layouts, e), "How the levels are placed: anywhere, on a grid, or in a line by their order")
		grid := LDtkDoc_WorldGrid(c.doc, wi)
		if layout == "GridVania" {
			e.op = .World_Grid_Width
			numberRow(c, "Grid width", "ldtk-world-grid-w", "The world grid's cells, in pixels (levels move with it)", e, f64(grid.x), 16, 0, 1, 100000)
			e.op = .World_Grid_Height
			numberRow(c, "Grid height", "ldtk-world-grid-h", "The world grid's cell height", e, f64(grid.y), 16, 0, 1, 100000)
		} else {
			note(c, fmt.tprintf("Grid: %d x %d (GridVania's: it applies when the layout is GridVania)", grid.x, grid.y))
		}
		linear := layout == "LinearHorizontal" || layout == "LinearVertical"
		heading(c, "Levels")
		if linear do note(c, "A linear world places its levels by their order (not editable here yet: reorder them in LDtk).", true)
		for _, i in c.doc.levels {
			if c.doc.levels[i].world != wi do continue
			name, iid := LDtkDoc_LevelNames(c.doc, i)
			rect := LDtkDoc_LevelRect(c.doc, i)
			if linear {
				note(c, fmt.tprintf("%s: %.0f x %.0f px, at %.0f, %.0f", name, rect[2], rect[3], rect[0], rect[1]))
				continue
			}
			move := base(c, .Level_X)
			move.level = strings.clone(iid, context.temp_allocator)
			step := layout == "GridVania" ? f64(grid.x) : 16
			numberRow(c, fmt.tprintf("%s X", name), fmt.tprintf("ldtk-world-x-%d", i), "Where the level's left edge is in the world (GridVania: snapped to the grid)", move, rect[0], step, 0, -1000000, 1000000)
			move.op = .Level_Y
			numberRow(c, fmt.tprintf("%s Y", name), fmt.tprintf("ldtk-world-y-%d", i), "Where its top edge is", move, rect[1], layout == "GridVania" ? f64(grid.y) : 16, 0, -1000000, 1000000)
		}
		_ = world
	}
	note(c, fmt.tprintf("Levels' sizes, names and new levels are LDtk's. This file is LDtk %s.", Json_String(main, Json_Get(main, Json_Root(main), "jsonVersion"))))
}

// Tilesets: what they are (LDtk edits them)
@(private="file")
ldtkTilesetsSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	sets := Json_Items(main, LDtkDoc_Defs(c.doc, "tilesets"))
	if len(sets) == 0 do note(c, "No tilesets.")
	for t in sets {
		heading(c, Json_String(main, Json_Get(main, t, "identifier")))
		image := Json_String(main, Json_Get(main, t, "relPath"))
		if image == "" do image = Json_String(main, Json_Get(main, t, "embedAtlas"))
		note(c, fmt.tprintf("%s, %d x %d px, %d px tiles (spacing %d, padding %d)", image == "" ? "no image" : image,
			Json_Int(main, Json_Get(main, t, "pxWid")), Json_Int(main, Json_Get(main, t, "pxHei")), Json_Int(main, Json_Get(main, t, "tileGridSize")),
			Json_Int(main, Json_Get(main, t, "spacing")), Json_Int(main, Json_Get(main, t, "padding"))))
	}
	note(c, "Tilesets are edited in LDtk (not here yet).")
}
