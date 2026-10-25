package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Level mode's bottom tabs that are LDtk's panels (the bottom panel's World, Level, Layers,
Entities, Enums, Tilesets, Auto-layer Rules and Project: `BottomTab`), for the Level mode's LDtk
project, its world and its selected level. Every control sends an `LDtk_Edit` (ldtk_ops.odin),
made in the document in memory (saved with the project), one undo step each; what isn't editable
here yet says so. Text fields keep what's typed while they have focus (State.numberEdit) and apply
it whenever it's a valid value; why the last edit wasn't made shows above the tab's rows
(`LevelMode.problem`).

What each shows (today's sections of the old LDtk tab, moved into LDtk's panels):
- **World:** the world (with several, a choice), its layout, grid, each level's place.
- **Level:** the selected level (size, place, counts), the scenes showing it (open them, New Scene
  with This Level), its custom fields, its neighbours.
- **Layers**, **Entities** (with their fields), **Enums**, **Tilesets**, and the **Level** tab's
  level fields: the definitions editors (view_ldtk_defs.odin); the Layers tab adds what scenes'
  LDtkLevel nodes make of an IntGrid layer's values (`ldtkIntGridKinds`), the Entities tab the
  type's entities in the level (one selected: its place and fields) and the level's entity
  references (the old Links).
- **Auto-layer Rules:** a summary (phase 4 edits them). **Project:** the file's settings, read
  only. The helpers (`tabRow`, `tabTextField`...) are shared with view_ldtk_defs.odin.

Widget keys: the rows' scroll `ldtk-tab-scroll`, an item choice `ldtk-item-<Tab>` (Layers,
Entities, Enums); World: `ldtk-world-choice`, `ldtk-world-layout`, `ldtk-world-grid-w`, `-grid-h`,
`ldtk-world-x-<i>`, `ldtk-world-y-<i>`; Level: `level-open-scene-<i>`, `level-new-scene`,
`level-manual`, `ldtk-level-field-<uid>`, `ldtk-level-field-name-<uid>`; Layers:
`ldtk-layer-name`, `-opacity`, `-parallax-x`, `-parallax-y`, `-parallax-scaling`, `-grid`,
`-visible`, `-up`, `-down`, `ldtk-intgrid-name-<value>`, `-color-<value>`,
`ldtk-kind-<value>-<scene>-<node>`; Entities: `ldtk-entity-name`, `-width`, `-height`, `-color`,
`-pivot-x`, `-pivot-y`, fields `ldtk-field-name-<uid>`, `ldtk-field-default-<uid>`, instances
`ldtk-instance-<i>`, the selected one's `ldtk-instance-x`, `-y`, `ldtk-instance-field-<uid>`,
references `ldtk-ref-<i>-<uid>` (the i-th entity's field); Enums: `ldtk-enum-name`,
`ldtk-enum-value-<i>`, `ldtk-enum-color-<i>`, `ldtk-enum-new-value`, `ldtk-enum-add-value`,
`ldtk-enum-new`, `ldtk-enum-add`; Project: `ldtk-project-save`.
*/

// The labels' column
@(private)
LDTK_LABEL_WIDTH :: 96

// What a tab builds with: the document, the edit every control starts from, widths
@(private)
LDtkTabCtx :: struct {
	s: ^State,
	ctx: ^skald.Ctx(Msg),
	doc: ^LDtkDoc,
	main: ^JsonDoc,
	// The project-relative .ldtk path (temp)
	file: string,
	// The shown world
	world: int,
	// The selected level (-1 none) and its iid (temp)
	level: int,
	levelIid: string,
	controlWidth, rowWidth: f32,
	// Rows stack their labels over their controls (a narrow panel)
	stacked: bool,
	rows: ^[dynamic]skald.View,
}

/*
One of the bottom panel's LDtk tabs (`tab`: World, Level, Layers, Entities, Enums, Tilesets,
Auto_Layer_Rules, LDtk_Project) for the Level mode's file (view_bottom.odin builds it).
*/
LevelMode_LDtkTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg), tab: BottomTab) -> skald.View {
	th := ctx.theme
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	if doc == nil do return skald.col(skald.text("The LDtk tabs edit the world's LDtk project: import an .ldtk file first (the Levels sidebar's Import...).", th.color.fg_muted, th.font.size_sm, max_width = max(Mode_LayoutOf(s, .Level).workspace.x - 500, 200)), padding = th.spacing.md)
	if doc.problem != "" do return placeholder(ctx, fmt.tprintf("%s can't be read as an LDtk project: %s", filepath.base(file), doc.problem))

	// The panel's width: the Level mode's center column
	layout := Mode_LayoutOf(s, .Level)
	left, right, _ := LevelMode_Sidebars(layout)
	panel := max(layout.workspace.x - left - right - DIVIDER * 2, LEVEL_MIN_CANVAS)
	content := max(panel - th.spacing.sm * 2 - 16, 120)
	stacked := content < LDTK_LABEL_WIDTH + 140
	control := stacked ? min(content, 260) : min(content - LDTK_LABEL_WIDTH - th.spacing.sm, 260)

	rows := make([dynamic]skald.View, context.temp_allocator)
	level := s.level.level != "" ? LDtkDoc_FindLevel(doc, s.level.level) : -1
	levelIid := ""
	if level >= 0 do _, levelIid = LDtkDoc_LevelNames(doc, level)
	c := LDtkTabCtx{s = s, ctx = ctx, doc = doc, main = LDtkDoc_Main(doc), file = strings.clone(file, context.temp_allocator), world = LevelMode_World(s, doc), level = level,
		levelIid = strings.clone(levelIid, context.temp_allocator), controlWidth = control, rowWidth = content, stacked = stacked, rows = &rows}
	if s.level.problem != "" do append(&rows, skald.text(fmt.tprintf("Not changed: %s", s.level.problem), th.color.warning, th.font.size_xs, max_width = content))
	if old := LDtkOps_TooOld(doc); old != "" do append(&rows, skald.text(fmt.tprintf("Read only: %s", old), th.color.warning, th.font.size_xs, max_width = content))
	#partial switch tab {
	case .World:            ldtkWorldSection(&c)
	case .Level:            ldtkLevelSection(&c)
	case .Layers:           ldtkLayersSection(&c)
	case .Entities:         ldtkEntitiesSection(&c)
	case .Enums:            ldtkEnumsSection(&c)
	case .Tilesets:         ldtkTilesetsSection(&c)
	case .Auto_Layer_Rules: ldtkRulesSection(&c)
	case .LDtk_Project:     ldtkProjectSection(&c)
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("ldtk-tab-scroll"))
}

// The base edit of the tab's controls (the file; temp strings)
@(private)
tabBase :: proc(c: ^LDtkTabCtx, op: LDtkEditOp) -> LDtk_Edit {
	return {op = op, file = c.file, level = c.levelIid}
}

// A row: a label (with its tooltip) beside its control, or over it in a narrow panel
@(private)
tabRow :: proc(c: ^LDtkTabCtx, label: string, control: skald.View, tip: string) {
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
@(private)
tabHeading :: proc(c: ^LDtkTabCtx, text: string) {
	th := c.ctx.theme
	append(c.rows, skald.spacer(th.spacing.xs), skald.text(text, th.color.fg, th.font.size_sm, max_width = c.rowWidth))
}

// A tabNote (`warning`: something not editable here, or a problem)
@(private)
tabNote :: proc(c: ^LDtkTabCtx, text: string, warning := false) {
	th := c.ctx.theme
	append(c.rows, skald.text(text, warning ? th.color.warning : th.color.fg_muted, th.font.size_xs, max_width = c.rowWidth))
}

// A text field: what's typed is kept while it has focus, sent with the edit (`edit.text`)
@(private)
tabTextField :: proc(c: ^LDtkTabCtx, key, value: string, edit: LDtk_Edit, width: f32 = 0) -> skald.View {
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
@(private)
tabNumberRow :: proc(c: ^LDtkTabCtx, label, key, tip: string, edit: LDtk_Edit, value, step: f64, decimals: int, lo, hi: f64) {
	tabRow(c, label, numberField(c.ctx, c.s, key, LDtkNumberTarget{edit}, value, step, decimals, min(c.controlWidth, 160), lo, hi), tip)
}

// A checkbox sending the edit with `flag`
@(private)
tabFlagRow :: proc(c: ^LDtkTabCtx, label, key, tip: string, edit: LDtk_Edit, value: bool) {
	box := skald.checkbox(c.ctx, value, "", edit, proc(edit: LDtk_Edit, v: bool) -> Msg {
		e := edit
		e.flag = v
		return e
	}, id = skald.hash_id(key))
	tabRow(c, label, box, tip)
}

// A color: its swatch and its #RRGGBB text field
@(private)
tabColorField :: proc(c: ^LDtkTabCtx, key, value: string, edit: LDtk_Edit) -> skald.View {
	color := skald.rgb(0x000000)
	if v, ok := LDtk_ParseColor(value); ok do color = skald.rgb(u32(v))
	swatch := skald.col(skald.spacer(0), width = 16, height = 16, bg = color, radius = 2)
	return skald.row(swatch, tabTextField(c, key, value, edit, max(c.controlWidth - 22, 60)), spacing = 6, cross_align = .Center)
}

// A select of labels sending `values[i]` as the edit's text
@(private)
tabChoiceField :: proc(c: ^LDtkTabCtx, key, shown: string, labels, values: []string, edit: LDtk_Edit) -> skald.View {
	return labeledSelect(c.ctx, shown, labels, values, edit, proc(edit: LDtk_Edit, v: string) -> Msg {
		e := edit
		e.text = v
		return e
	}, id = skald.hash_id(key), width = c.controlWidth)
}

// The section's item choice: definitions by name, the selected one's uid (the first when it's gone)
@(private)
tabItemChoice :: proc(c: ^LDtkTabCtx, tab: BottomTab, list: int, selected: int, label: string, filter: proc(json: ^JsonDoc, node: int) -> bool = nil) -> int {
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
	Pick :: struct { tab: BottomTab }
	picker := labeledSelect(c.ctx, shown, names[:], uids[:], Pick{tab}, proc(p: Pick, v: string) -> Msg {
		uid, _ := tabParseInt(v)
		return LDtk_Item_Picked{p.tab, uid}
	}, id = skald.hash_id(fmt.tprintf("ldtk-item-%v", tab)), width = c.controlWidth)
	tabRow(c, label, picker, "Which one the section shows")
	return chosen
}

@(private)
tabParseInt :: proc(text: string) -> (int, bool) {
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
@(private)
tabValueText :: proc(json: ^JsonDoc, node: int) -> string {
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

// Layers: the layer definitions' editor (view_ldtk_defs.odin)
@(private="file")
ldtkLayersSection :: proc(c: ^LDtkTabCtx) {
	LDtkDefs_Layers(c)
}

// Entities: the type's settings, its fields' definitions, its instances in the selected level
@(private="file")
ldtkEntitiesSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	th := c.ctx.theme
	def := LDtkDefs_Entities(c)
	if def < 0 do return
	uid := Json_Int(main, Json_Get(main, def, "uid"))

	tabHeading(c, c.level >= 0 ? fmt.tprintf("In %s", c.s.level.level) : "Placed (every level)")
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
		move := tabBase(c, .Entity_X)
		move.entity = strings.clone(iid, context.temp_allocator)
		tabNumberRow(c, "X", "ldtk-instance-x", "Where the entity's pivot is in its level, pixels from the left", move, f64(x), 1, 0, -100000, 100000)
		move.op = .Entity_Y
		tabNumberRow(c, "Y", "ldtk-instance-y", "Pixels from the top", move, f64(y), 1, 0, -100000, 100000)
		for fi in Json_Items(json, Json_Get(json, en.node, "fieldInstances")) {
			fieldUid := Json_Int(json, Json_Get(json, fi, "defUid"), -1)
			_, fieldDef := LDtkDoc_FieldDef(c.doc, fieldUid)
			if fieldDef < 0 do continue
			info := LDtkDoc_FieldInfo(c.doc, fieldDef)
			e := tabBase(c, info.type == .EntityRef ? .Entity_Ref : .Entity_Field)
			e.entity = move.entity
			e.field = fieldUid
			fieldControl(c, info, json, fi, en, e, fmt.tprintf("ldtk-instance-field-%d", fieldUid))
		}
	}
	if shown == 0 do tabNote(c, c.level >= 0 ? "None in this level." : "None placed.")
	tabNote(c, "Click one to select it (on the canvas too, where a drag moves it).")
	ldtkReferences(c)
}

// A field's default as its field shows it (strings unquoted, none empty)
@(private="file")
ldtkDefaultShown :: proc(info: LDtkFieldInfo) -> string {
	if info.defaultText == "null" do return ""
	doc, problem := Json_Parse(info.defaultText, context.temp_allocator)
	if problem != "" do return info.defaultText
	return strings.clone(tabValueText(&doc, 0), context.temp_allocator)
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
	// Points and references picked on the canvas (level_paint.odin's LevelPick), arrays too
	if edit.op != .Level_Field && (info.type == .Point || (info.type == .EntityRef && (info.isArray || info.symmetrical))) {
		pickedFieldControl(c, info, json, fi, owner, edit, key, label, tip)
		return
	}
	why := LDtkOps_FieldLocked(info)
	if why == "" && edit.op == .Level_Field && info.type == .EntityRef do why = "a level's entity references aren't editable here yet (LDtk edits them)"
	if why != "" {
		tabRow(c, label, skald.text(Json_Text(json, value), c.ctx.theme.color.fg, c.ctx.theme.font.size_xs, max_width = c.controlWidth), tip)
		tabNote(c, fmt.tprintf("   %s", why), true)
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
		tabRow(c, label, box, tip)
	case .Enum:
		values := LDtkDoc_EnumValues(c.doc, info.enumUid)
		labels := make([dynamic]string, context.temp_allocator)
		vals := make([dynamic]string, context.temp_allocator)
		append(&labels, "(default)")
		append(&vals, "")
		append(&labels, ..values)
		append(&vals, ..values)
		shown := tabValueText(json, value)
		tabRow(c, label, tabChoiceField(c, key, shown == "" ? "(default)" : shown, labels[:], vals[:], edit), tip)
	case .EntityRef:
		labels, vals := refChoices(c, info, owner)
		shown := "(none)"
		target := tabValueText(json, value)
		for v, i in vals do if v == target && target != "" do shown = labels[i]
		tabRow(c, label, tabChoiceField(c, key, shown, labels, vals, edit), tip)
		if edit.op == .Entity_Ref do append(c.rows, tabPickButton(c, fmt.tprintf("%s-pick", key), "Pick on the canvas", Level_Pick_Started{.Ref, edit.entity, edit.field, 0}))
	case:
		tabRow(c, label, tabTextField(c, key, tabValueText(json, value), edit), tip)
	}
}

// A button starting a pick on the canvas (the Entities tab's: a reference's target, a point's cell)
@(private)
tabPickButton :: proc(c: ^LDtkTabCtx, key, label: string, pick: Level_Pick_Started) -> skald.View {
	th := c.ctx.theme
	waiting := c.s.level.paint.pick.kind == pick.kind && c.s.level.paint.pick.entity == pick.entity && c.s.level.paint.pick.field == pick.field && c.s.level.paint.pick.index == pick.index
	p := pick
	p.entity = strings.clone(pick.entity, context.temp_allocator)
	msg := Msg(p)
	if waiting do msg = Msg(Level_Pick_Started{})
	b := skald.button(c.ctx, waiting ? fmt.tprintf("%s  Picking... (Esc)", ICON_CROSSHAIRS) : fmt.tprintf("%s  %s", ICON_CROSSHAIRS, label), msg, id = skald.hash_id(key),
		bg = waiting ? th.color.primary : th.color.surface, fg = waiting ? th.color.on_primary : th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	return skald.row(skald.spacer(c.stacked ? 0 : LDTK_LABEL_WIDTH), b, spacing = th.spacing.sm)
}

/*
A point field (a cell of the entity's layer) or an array / symmetrical entity reference field:
its values, each removable, and a Pick button: the next click on the canvas sets it (an array's
picks add, LDtk's point picker keeps adding until Esc).
*/
@(private="file")
pickedFieldControl :: proc(c: ^LDtkTabCtx, info: LDtkFieldInfo, json: ^JsonDoc, fi: int, owner: LDtkDocEntity, edit: LDtk_Edit, key, label, tip: string) {
	th := c.ctx.theme
	value := Json_Get(json, fi, "__value")
	items := info.isArray ? Json_Items(json, value) : []int{value}
	kind := info.type == .Point ? LevelPickKind.Point : LevelPickKind.Ref
	describe :: proc(c: ^LDtkTabCtx, json: ^JsonDoc, item: int, point: bool) -> string {
		if Json_Kind(json, item) != .Object do return "(none)"
		if point do return fmt.tprintf("cell %d, %d", Json_Int(json, Json_Get(json, item, "cx")), Json_Int(json, Json_Get(json, item, "cy")))
		iid := Json_String(json, Json_Get(json, item, "entityIid"))
		if target, found := LDtkDoc_FindEntity(c.doc, iid); found {
			tj := LDtkDoc_Json(c.doc, target.file)
			level, _ := LDtkDoc_LevelNames(c.doc, target.level)
			return fmt.tprintf("%s in %s", Json_String(tj, Json_Get(tj, target.node, "__identifier")), level)
		}
		return iid
	}
	tabRow(c, label, skald.text(info.isArray ? fmt.tprintf("%d item(s)", len(items)) : describe(c, json, value, kind == .Point), th.color.fg, th.font.size_xs, max_width = c.controlWidth), tip)
	for item, i in items {
		if !info.isArray do break
		remove := edit
		remove.entity = strings.clone(edit.entity, context.temp_allocator)
		remove.index = i
		if kind == .Point {
			remove.op = .Entity_Point
			remove.flag = true
		} else {
			remove.op = .Entity_Ref
			remove.text = ""
		}
		x := skald.button(c.ctx, ICON_XMARK, Msg(remove), id = skald.hash_id(fmt.tprintf("%s-remove-%d", key, i)), bg = th.color.surface, fg = th.color.fg_muted, padding = {th.spacing.xs, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
		append(c.rows, skald.row(skald.spacer(c.stacked ? 0 : LDTK_LABEL_WIDTH), skald.text(fmt.tprintf("%d. %s", i + 1, describe(c, json, item, kind == .Point)), th.color.fg_muted, th.font.size_xs), x, spacing = th.spacing.sm, cross_align = .Center))
	}
	if !info.isArray && Json_Kind(json, value) == .Object {
		clear := edit
		clear.entity = strings.clone(edit.entity, context.temp_allocator)
		if kind == .Point {
			clear.op = .Entity_Point
			clear.flag = true
		} else {
			clear.op = .Entity_Ref
			clear.text = ""
		}
		append(c.rows, skald.row(skald.spacer(c.stacked ? 0 : LDTK_LABEL_WIDTH), skald.button(c.ctx, "Clear", Msg(clear), id = skald.hash_id(fmt.tprintf("%s-clear", key)), bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)))
	}
	append(c.rows, tabPickButton(c, fmt.tprintf("%s-pick", key), info.isArray ? (kind == .Point ? "Add points on the canvas" : "Add a reference on the canvas") : "Pick on the canvas",
		Level_Pick_Started{kind, edit.entity, edit.field, info.isArray ? -1 : 0}))
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

// What scenes' LDtkLevel nodes make of an IntGrid layer's values (the old Collisions)
@(private)
ldtkIntGridKinds :: proc(c: ^LDtkTabCtx, def: int) {
	main := c.main
	identifier := Json_String(main, Json_Get(main, def, "identifier"))
	values := Json_Items(main, Json_Get(main, def, "intGridValues"))
	tabHeading(c, "In the scenes")
	tabNote(c, "What each value becomes in a game (solid, one-way, an area) is the scene's LDtkLevel node's.")
	// The engine's collision kinds, per LDtkLevel node using this layer for collision
	found := false
	kinds := make([dynamic]string, context.temp_allocator)
	for label in LDTK_KIND_LABELS do append(&kinds, label)
	for &scene, si in c.s.project.scenes {
		if Scene_IsComponent(&scene) do continue
		for &node, ni in scene.nodes {
			if node.kind != .LDtkLevel || node.ldtk.file != c.file || node.ldtk.collisionLayer != identifier do continue
			found = true
			tabHeading(c, fmt.tprintf("In %s, %s makes them:", scene.name, node.name))
			Kind :: struct { scene, node, value: int }
			for v in values {
				value := Json_Int(main, Json_Get(main, v, "value"))
				name := Json_String(main, Json_Get(main, v, "identifier"))
				choice := skald.select(c.ctx, LDTK_KIND_LABELS[e.LDtk_CollisionKind(&node.ldtk, value)], kinds[:], Kind{si, ni, value}, proc(k: Kind, label: string) -> Msg {
					kind := e.LDtkCollisionKind.None
					for l, kd in LDTK_KIND_LABELS do if l == label do kind = kd
					return Level_Collision_Kind_Changed{k.scene, k.node, k.value, kind}
				}, id = skald.hash_id(fmt.tprintf("ldtk-kind-%d-%d-%d", value, si, ni)), width = c.controlWidth)
				tabRow(c, name != "" ? fmt.tprintf("%d %s", value, name) : fmt.tprintf("Value %d", value), choice, "What the LDtkLevel node makes of the value's cells")
			}
		}
	}
	if !found do tabNote(c, fmt.tprintf("No scene's LDtkLevel node uses %s for collision yet: pick it in the node's inspector (Collision).", identifier))
}

// The entity reference fields of the selected level's entities (every level's without one), retargeted here
@(private="file")
ldtkReferences :: proc(c: ^LDtkTabCtx) {
	tabHeading(c, c.level >= 0 ? fmt.tprintf("References in %s", c.s.level.level) : "References (every level)")
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
			e := tabBase(c, .Entity_Ref)
			e.entity = strings.clone(iid, context.temp_allocator)
			e.field = info.uid
			info.identifier = fmt.tprintf("%s.%s", Json_String(json, Json_Get(json, en.node, "__identifier")), info.identifier)
			fieldControl(c, info, json, fi, en, e, fmt.tprintf("ldtk-ref-%d-%d", i, info.uid))
		}
	}
	if !any do tabNote(c, "No entity reference fields here.")
}

// The selected level's neighbours (LDtk works them out from where levels are)
@(private="file")
ldtkNeighbours :: proc(c: ^LDtkTabCtx) {
	tabHeading(c, "Neighbours")
	neighbours := LDtkDoc_Neighbours(c.doc, c.level)
	if len(neighbours) == 0 do tabNote(c, "None: no level touches or overlaps this one.")
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
		tabNote(c, fmt.tprintf("%s: %s", dirName(n.dir), name))
	}
	tabNote(c, "LDtk works neighbours out from where the levels are: drag levels on the canvas (or set their places in the World tab) to change them.")
}

/*
Level: the selected level (its size, place and counts), the scenes showing it (open them, or New
Scene with This Level), its custom fields, its neighbours; without one, how many levels the world
has and the level fields' names.
*/
@(private="file")
ldtkLevelSection :: proc(c: ^LDtkTabCtx) {
	s := c.s
	ctx := c.ctx
	th := ctx.theme
	doc := c.doc
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	if c.level < 0 {
		count := len(LevelMode_WorldLevels(s, doc))
		tabHeading(c, fmt.tprintf("%d level%s in this world", count, count == 1 ? "" : "s"))
		tabNote(c, "Select a level (the Levels sidebar or the canvas) to see it here: its size and place, the scenes showing it, its fields and neighbours. Double-click one to focus it.")
		ldtkLevelFieldsSection(c)
		append(c.rows, button(ctx, "level-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("level_mode"))))
		return
	}
	main := c.main
	identifier, _ := LDtkDoc_LevelNames(doc, c.level)
	rect := LDtkDoc_LevelRect(doc, c.level)
	entities := 0
	for e in LDtkDoc_Entities(doc) do if e.level == c.level do entities += 1
	_, layers := LDtkDoc_LayerInstances(doc, c.level)
	layerCount := Json_Count(LDtkDoc_Json(doc, doc.levels[c.level].file), layers)
	fields := Json_Count(main, Json_Get(main, doc.levels[c.level].entry, "fieldInstances"))
	neighbours := len(LDtkDoc_Neighbours(doc, c.level))
	append(c.rows, skald.text(fmt.tprintf("%s  %s", ICON_FILE_LINES, identifier), th.color.fg, th.font.size_sm, max_width = c.rowWidth))
	tabNote(c, fmt.tprintf("%.0f x %.0f px, at %.0f, %.0f in the world", rect[2], rect[3], rect[0], rect[1]))
	tabNote(c, fmt.tprintf("%d layer%s, %d entit%s, %d field%s, %d neighbour%s", layerCount, layerCount == 1 ? "" : "s",
		entities, entities == 1 ? "y" : "ies", fields, fields == 1 ? "" : "s", neighbours, neighbours == 1 ? "" : "s"))
	if e, found := LDtkDoc_FindEntity(doc, s.level.entity); found && s.level.entity != "" && e.level == c.level {
		json := LDtkDoc_Json(doc, e.file)
		px := Json_Get(json, e.node, "px")
		tabNote(c, fmt.tprintf("Selected: %s at %d, %d (the Entities tab edits it)", Json_String(json, Json_Get(json, e.node, "__identifier")),
			Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))))
	}
	tabHeading(c, "Scenes showing it")
	shown := LevelMode_ScenesShowing(s, c.file, identifier)
	if len(shown) == 0 {
		tabNote(c, "No scene shows this level.")
		append(c.rows, button(ctx, "level-new-scene", fmt.tprintf("%s  New Scene with This Level", ICON_PLUS), Msg(Level_Scene_Created{})))
	} else {
		for at, i in shown {
			scene := &s.project.scenes[at.scene]
			label := fmt.tprintf("%s  %s (%s%s)", ICON_ARROW_RIGHT, scene.name, scene.nodes[at.node].name, at.allLevels ? ", the whole world" : "")
			append(c.rows, button(ctx, fmt.tprintf("level-open-scene-%d", i), label, Msg(Level_Scene_Opened{at.scene, at.node})))
		}
	}
	ldtkLevelFieldsSection(c)
	ldtkNeighbours(c)
	append(c.rows, skald.spacer(th.spacing.xs), button(ctx, "level-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("level_mode"))))
}

// The level fields: the selected level's values, then their definitions (LDtk's level panel opens
// EditLevelFieldDefs: view_ldtk_defs.odin)
@(private="file")
ldtkLevelFieldsSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	defs := Json_Items(main, LDtkDoc_Defs(c.doc, "levelFields"))
	if c.level >= 0 && len(defs) > 0 {
		tabHeading(c, fmt.tprintf("%s's fields", c.s.level.level))
		entry := c.doc.levels[c.level].entry
		for fi in Json_Items(main, Json_Get(main, entry, "fieldInstances")) {
			uid := Json_Int(main, Json_Get(main, fi, "defUid"), -1)
			_, fieldDef := LDtkDoc_FieldDef(c.doc, uid)
			if fieldDef < 0 do continue
			info := LDtkDoc_FieldInfo(c.doc, fieldDef)
			e := tabBase(c, .Level_Field)
			e.field = uid
			fieldControl(c, info, main, fi, {level = c.level}, e, fmt.tprintf("ldtk-level-field-%d", uid))
		}
		tabNote(c, "Empty: the field's default. Games read them with e.LDtk_FieldValue.")
	}
	LDtkDefs_LevelFields(c)
}

// Enums: the enums' editor (view_ldtk_defs.odin)
@(private="file")
ldtkEnumsSection :: proc(c: ^LDtkTabCtx) {
	LDtkDefs_Enums(c)
}

// World: the shown world (with several, a choice), its layout and grid, each level's place
@(private="file")
ldtkWorldSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	wi := c.world
	if len(c.doc.worlds) > 1 {
		names := make([dynamic]string, context.temp_allocator)
		iids := make([dynamic]string, context.temp_allocator)
		for _, w in c.doc.worlds {
			name, iid := LDtkDoc_WorldNames(c.doc, w)
			append(&names, name)
			append(&iids, iid)
		}
		_, shown := LDtkDoc_WorldNames(c.doc, wi)
		tabRow(c, "World", labeledSelect(c.ctx, shown, names[:], iids[:], 0, proc(_: int, iid: string) -> Msg { return Level_World_Chosen(iid) },
			id = skald.hash_id("ldtk-world-choice"), width = c.controlWidth), "Which of the project's worlds shows (LDtk's Multi-worlds): the canvas and the Levels sidebar show its levels")
	}
	layout := LDtkDoc_WorldLayout(c.doc, wi)
	e := tabBase(c, .World_Layout)
	e.world = wi
	layouts := []string{"Free", "GridVania", "LinearHorizontal", "LinearVertical"}
	labels := []string{"Free", "GridVania (on a grid)", "Linear, side by side", "Linear, one above the other"}
	tabRow(c, "Layout", tabChoiceField(c, "ldtk-world-layout", layout, labels, layouts, e), "How the levels are placed: anywhere, on a grid, or in a line by their order")
	grid := LDtkDoc_WorldGrid(c.doc, wi)
	if layout == "GridVania" {
		e.op = .World_Grid_Width
		tabNumberRow(c, "Grid width", "ldtk-world-grid-w", "The world grid's cells, in pixels (levels move with it)", e, f64(grid.x), 16, 0, 1, 100000)
		e.op = .World_Grid_Height
		tabNumberRow(c, "Grid height", "ldtk-world-grid-h", "The world grid's cell height", e, f64(grid.y), 16, 0, 1, 100000)
	} else {
		tabNote(c, fmt.tprintf("Grid: %d x %d (GridVania's: it applies when the layout is GridVania)", grid.x, grid.y))
	}
	linear := layout == "LinearHorizontal" || layout == "LinearVertical"
	tabHeading(c, "Levels")
	if linear do tabNote(c, "A linear world places its levels by their order (not editable here yet: reorder them in LDtk).", true)
	for _, i in c.doc.levels {
		if c.doc.levels[i].world != wi do continue
		name, iid := LDtkDoc_LevelNames(c.doc, i)
		rect := LDtkDoc_LevelRect(c.doc, i)
		if linear {
			tabNote(c, fmt.tprintf("%s: %.0f x %.0f px, at %.0f, %.0f", name, rect[2], rect[3], rect[0], rect[1]))
			continue
		}
		move := tabBase(c, .Level_X)
		move.level = strings.clone(iid, context.temp_allocator)
		step := layout == "GridVania" ? f64(grid.x) : 16
		tabNumberRow(c, fmt.tprintf("%s X", name), fmt.tprintf("ldtk-world-x-%d", i), "Where the level's left edge is in the world (GridVania: snapped to the grid)", move, rect[0], step, 0, -1000000, 1000000)
		move.op = .Level_Y
		tabNumberRow(c, fmt.tprintf("%s Y", name), fmt.tprintf("ldtk-world-y-%d", i), "Where its top edge is", move, rect[1], layout == "GridVania" ? f64(grid.y) : 16, 0, -1000000, 1000000)
	}
	tabNote(c, fmt.tprintf("Levels' sizes, names and new levels are LDtk's for now. This file is LDtk %s.", Json_String(main, Json_Get(main, Json_Root(main), "jsonVersion"))))
}

// Tilesets: the tilesets' editor (view_ldtk_defs.odin)
@(private="file")
ldtkTilesetsSection :: proc(c: ^LDtkTabCtx) {
	LDtkDefs_Tilesets(c)
}

// Auto-layer rules: a summary of each layer's rule groups (they're edited in LDtk until phase 4)
@(private="file")
ldtkRulesSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	tabNote(c, "Auto-layer rules paint tiles from an IntGrid layer's values. They're edited in LDtk for now: this tab edits them in phase 4 of the Level editor.", true)
	any := false
	for d in Json_Items(main, LDtkDoc_Defs(c.doc, "layers")) {
		groups := Json_Items(main, Json_Get(main, d, "autoRuleGroups"))
		if len(groups) == 0 do continue
		any = true
		tabHeading(c, fmt.tprintf("%s (%s)", Json_String(main, Json_Get(main, d, "identifier")), Json_String(main, Json_Get(main, d, "__type"))))
		for g in groups {
			rules := Json_Items(main, Json_Get(main, g, "rules"))
			active := 0
			for r in rules do if Json_Bool(main, Json_Get(main, r, "active"), true) do active += 1
			name := Json_String(main, Json_Get(main, g, "name"))
			tabNote(c, fmt.tprintf("%s: %d rule%s, %d active%s", name == "" ? "(no name)" : name, len(rules), len(rules) == 1 ? "" : "s", active,
				Json_Bool(main, Json_Get(main, g, "active"), true) ? "" : " (the group is off)"))
		}
	}
	if !any do tabNote(c, "No layer of this project has auto-layer rules.")
}

// Project: the LDtk file's own settings, read only (phase 5 edits them), and whether it's saved
@(private="file")
ldtkProjectSection :: proc(c: ^LDtkTabCtx) {
	main := c.main
	root := Json_Root(main)
	th := c.ctx.theme
	unsaved := LDtkDoc_IsUnsaved(c.s.project.rootPath, c.file)
	text :: proc(c: ^LDtkTabCtx, value: string) -> skald.View {
		return skald.text(value, c.ctx.theme.color.fg, c.ctx.theme.font.size_sm, max_width = c.controlWidth)
	}
	tabRow(c, "File", text(c, c.file), "The LDtk project's file, in the project's assets")
	files := len(c.doc.files) - 1
	if files > 0 do tabNote(c, fmt.tprintf("Its levels are saved apart: %d .ldtkl file%s beside it", files, files == 1 ? "" : "s"))
	status := skald.row(
		skald.text(unsaved ? "Unsaved edits" : "Saved", unsaved ? th.color.warning : th.color.fg_muted, th.font.size_sm),
		skald.button(c.ctx, fmt.tprintf("%s  Save", ICON_SAVE), Msg(Action.Save_Project), id = skald.hash_id("ldtk-project-save"), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = !unsaved),
		spacing = th.spacing.sm, cross_align = .Center)
	tabRow(c, "Saved", status, "The Level mode's edits stay in memory until you save (Ctrl+S), play or export")
	tabRow(c, "LDtk version", text(c, Json_String(main, Json_Get(main, root, "jsonVersion"))), "The LDtk version that last saved the file")
	worlds := len(c.doc.worlds)
	tabRow(c, "Worlds", text(c, fmt.tprintf("%d (%d level%s)", worlds, len(c.doc.levels), len(c.doc.levels) == 1 ? "" : "s")), "LDtk's Multi-worlds: a project with several worlds")
	tabRow(c, "Identifiers", text(c, Json_String(main, Json_Get(main, root, "identifierStyle"))), "How LDtk writes names (Capitalize, Uppercase, Lowercase, Free): renames here follow it")
	tabRow(c, "Default grid", text(c, fmt.tprintf("%d px", Json_Int(main, Json_Get(main, root, "defaultGridSize"), 16))), "The cell size of new layers")
	tabRow(c, "Level size", text(c, fmt.tprintf("%d x %d px", Json_Int(main, Json_Get(main, root, "defaultLevelWidth"), 256), Json_Int(main, Json_Get(main, root, "defaultLevelHeight"), 256))), "The size of new levels")
	tabRow(c, "Background", tabColorSwatch(c, Json_String(main, Json_Get(main, root, "defaultLevelBgColor"))), "New levels' background color")
	tabRow(c, "Separate files", text(c, Json_Bool(main, Json_Get(main, root, "externalLevels")) ? "Yes: each level in a .ldtkl file" : "No: levels in the project file"), "LDtk's \"Save levels to separate files\"")
	tabNote(c, "These are edited in LDtk for now (Project settings): phase 5 of the Level editor edits them here.")
}

// A color's swatch and text (read only)
@(private)
tabColorSwatch :: proc(c: ^LDtkTabCtx, value: string) -> skald.View {
	color := skald.rgb(0x000000)
	if v, ok := LDtk_ParseColor(value); ok do color = skald.rgb(u32(v))
	return skald.row(skald.col(skald.spacer(0), width = 16, height = 16, bg = color, radius = 2), skald.text(value, c.ctx.theme.color.fg, c.ctx.theme.font.size_sm), spacing = 6, cross_align = .Center)
}
