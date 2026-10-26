package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "gui:skald"

/*
The Auto-layer Rules tab (phase 4 of TODO.md's "LDtk level editor"): LDtk's rule panel
(EditAllAutoLayerRules) and its rule editor (RuleEditor, with RuleModuloEditor,
RuleRandomOffsets and RulePerlinSettings as its sections), the Rule Assistant (RulesWizard) and
Duplicate and Remap (RuleGroupRemap) as the tab's pages (level_rules.odin's `LevelRulesPage`), so
the canvas stays in view: every edit applies at once and the level shows it (the rules applied
again: ldtk_rule_ops.odin).

**The list** (LDtk's panel), in the bottom tabs' shared layout (view_list_tab.odin): the sidebar
lists the layers with rules (IntGrid layers and AutoLayers, their groups counted: a pick selects
the layer), the toolbar row has + Group (a menu: the Assistant or an empty group), Paste group,
Randomize (the selected level's layer seed), Render (the auto-layers' tiles shown: Shift+R); the
rows start with the level's tileset (one of the same size). Each group: its
grip (drag to reorder), its toggle (on / off; an optional group's eye: on or off in the selected
level), its icon, its name (a click opens or closes it; hovering it outlines its rules' cells on
the canvas), its biomes, + (a rule first) or the Assistant's Edit, its menu (⋯ or a right click:
copy, cut, paste, duplicate, delete, rename, duplicate and remap, color, icon, every rule's
out-of-bounds policy, the Assistant, biomes, optional). Each rule: its grip (drag, into another
group too), toggle, pattern (a click opens its editor; hovering it outlines its cells), chance,
opacity, break on match, X / Y mirrors, offsets, modulos, Perlin (a right click: its settings),
a rule before or after it; its menu (copy, cut, paste, duplicate, delete). Rules putting tiles in
the cell under the canvas's pointer are highlighted (LDtk's onEditorMouseMove).

**The rule editor**: the tile mode and tiles (picked on the tileset: a drag replaces, Shift adds,
the right button removes; stamps one rectangle each, a stamp's pivot), the pattern (9 x 9, LDtk's
buttons: left requires the value, right forbids it, middle clears; a drag paints), the value
palette (values by group, a group itself, "any value / no value"), the out-of-bounds policy,
then the options of LDtk's dialogs: chance, opacity, break on match, mirrors, modulos with their
offsets, checker and preview, tile offsets and random offsets (linked), Perlin (seed, scale,
octaves, its noise shown on the level).

Widget keys: the list `ldtk-list-Auto_Layer_Rules` (its dropdown `ldtk-item-Auto_Layer_Rules`),
`ldtk-rules-add-group`, `-paste-group`, `-randomize`, `-render`, `-tileset`, `-settings`; a group's `ldtk-group-row-<uid>`, `-grip-`, `-toggle-`, `-name-`,
`-rename-`, `-add-`, `-edit-`, `-menu-`, `-advanced-`; a rule's `ldtk-rule-row-<uid>`, `-grip-`,
`-toggle-`, `-preview-`, `-chance-`, `-alpha-`, `-break-`, `-flipx-`, `-flipy-`, `-offset-`,
`-modulo-`, `-perlin-`, `-before-`, `-after-`; the editor's `ldtk-rule-close`, `-help`,
`-tilemode`, `-tiles` (the picker), `-stamp-<i>`, `-stamp-add`, `-pivot-<x>-<y>`, `-value-<v>`,
`-value-any`, `-pattern`, `-oob`, `-<member>` (`ldtk-rule-chance`, `ldtk-rule-xModulo`...),
`-link-x`, `-link-y`, `-perlin-random`, `-perlin-preview`; the Assistant's `ldtk-assistant-main`,
`-other`, `-name`, `-grid`, `-tiles`, `-stack`, `-clear`, `-create`, `-cancel`; the remap's
`ldtk-remap-<old value>`, `-tiles`, `-name`, `-confirm`, `-cancel`; the icon's `ldtk-icon-tiles`,
`-cancel`; the color's `ldtk-color-<i>`, `-hex`, `-none`, `-cancel`.
*/

// The rules tab (view_ldtk_tab.odin's Auto-layer Rules)
LDtkRules_Tab :: proc(c: ^LDtkTabCtx) {
	s := c.s
	main := c.main
	layerUid, layer := LevelRules_Layer(s, c.doc)
	c.list.empty = "No IntGrid layer or auto-layer: add one in the Layers tab."
	if layer < 0 {
		tabNote(c, "Auto-layer rules paint tiles from an IntGrid layer's values: this project has no IntGrid layer or auto-layer yet (add one in the Layers tab).")
		LevelRules_SetHovered(-1, -1, -1)
		return
	}
	// The list: IntGrid layers and AutoLayers, each with its groups' count; a pick selects the layer
	for d in Json_Items(main, LDtkDoc_Defs(c.doc, "layers")) {
		t := Json_String(main, Json_Get(main, d, "type"))
		if t != "IntGrid" && t != "AutoLayer" do continue
		n := Json_Count(main, Json_Get(main, d, "autoRuleGroups"))
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		row := ColoredTreeRow{label = fmt.tprintf("%s (%d)", Json_String(main, Json_Get(main, d, "identifier")), n), icon = LevelLayer_Icon(t), selected = uid == layerUid}
		if color, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, d, "uiColor"))); ok do row.iconColor = skald.rgb(u32(color))
		tabListItem(c, row, Msg(Rules_View{op = .Layer, uid = uid}))
	}
	groups := Json_Count(main, Json_Get(main, layer, "autoRuleGroups"))
	c.list.text = fmt.tprintf("%s: %d group%s of rules", Json_String(main, Json_Get(main, layer, "identifier")), groups, groups == 1 ? "" : "s")
	switch s.level.rules.page {
	case .List: rulesList(c, layerUid, layer)
	case .Editor: rulesEditor(c, layerUid, layer)
	case .Assistant: rulesAssistant(c, layerUid, layer)
	case .Remap: rulesRemap(c, layerUid, layer)
	case .Icon: rulesIcon(c, layerUid, layer)
	case .Color: rulesColor(c, layerUid, layer)
	}
}

// --- Shared pieces -------------------------------------------------------------------------------

// A small button
@(private="file")
rButton :: proc(c: ^LDtkTabCtx, key, label: string, msg: Msg, on := false, disabled := false, width: f32 = 0) -> skald.View {
	tk := uiTokens(c.ctx)
	th := c.ctx.theme
	return skald.button(c.ctx, label, msg, id = skald.hash_id(key), bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg,
		padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm, disabled = disabled, width = width)
}

// A small button with a tooltip
@(private="file")
rTipButton :: proc(c: ^LDtkTabCtx, key, label, tip: string, msg: Msg, on := false, disabled := false) -> skald.View {
	return skald.tooltip(c.ctx, rButton(c, key, label, msg, on, disabled), tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
}

// A row of buttons, wrapped in a narrow panel
@(private="file")
rButtons :: proc(c: ^LDtkTabCtx, buttons: ..skald.View) {
	views := make([]skald.View, len(buttons), context.temp_allocator)
	copy(views, buttons)
	append(c.rows, skald.wrap_row(..views, spacing = c.ctx.theme.spacing.xs, line_spacing = c.ctx.theme.spacing.xs, width = c.rowWidth))
}

// The base of a rule edit of the tab's layer
@(private="file")
rEdit :: proc(c: ^LDtkTabCtx, op: LDtkEditOp, layer: int, group := -1, rule := -1) -> LDtk_Edit {
	e := tabBase(c, op)
	e.def, e.index, e.field = layer, group, rule
	return e
}

// A rule's member set
@(private="file")
rSet :: proc(c: ^LDtkTabCtx, layer, rule: int, key: string) -> LDtk_Edit {
	e := rEdit(c, .Rule_Set, layer, rule = rule)
	e.key = key
	return e
}

// A zone around a view (its own hit-testing: presses, hovers)
@(private="file")
rZone :: proc(key: string, child: skald.View) -> skald.View {
	p := new(skald.View, context.temp_allocator)
	p^ = child
	return skald.View_Zone{id = skald.hash_id(key), child = p}
}

// Whether the pointer is in a widget's last rect (and its clip: inside the tab's scroll)
@(private="file")
rHovered :: proc(ctx: ^skald.Ctx(Msg), id: skald.Widget_ID) -> bool {
	if !skald.widget_hovered(ctx, id) || skald.mouse_over_overlay(ctx) || Overlay_PopupOpen(ctx) do return false
	if st, ok := ctx.widgets.states[id]; ok && st.clip_rect.w > 0 {
		m := ctx.input.mouse_pos
		r := st.clip_rect
		if m.x < r.x || m.y < r.y || m.x >= r.x + r.w || m.y >= r.y + r.h do return false
	}
	return true
}

// A tileset as the tab draws its tiles
@(private="file")
RulesTileset :: struct {
	uid: int,
	path: string,
	size: [2]f32,
	grid, spacing, padding: f32,
	cWid, cHei: int,
	ok: bool,
}

@(private="file")
rTileset :: proc(c: ^LDtkTabCtx, uid: int) -> RulesTileset {
	main := c.main
	td := LDtkDoc_DefByUid(c.doc, "tilesets", uid)
	if td < 0 do return {uid = uid}
	rel := Json_String(main, Json_Get(main, td, "relPath"))
	if rel == "" && Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do rel = "finalbossblues-icons_full_16.png"
	path := joinPath(LDtkDoc_Folder(c.doc), rel, allocator = context.temp_allocator)
	return {
		uid = uid, path = path, ok = rel != "" && os.exists(path),
		size = {f32(Json_Int(main, Json_Get(main, td, "pxWid"))), f32(Json_Int(main, Json_Get(main, td, "pxHei")))},
		grid = f32(max(Json_Int(main, Json_Get(main, td, "tileGridSize"), 16), 1)),
		spacing = f32(Json_Int(main, Json_Get(main, td, "spacing"))),
		padding = f32(Json_Int(main, Json_Get(main, td, "padding"))),
		cWid = max(Json_Int(main, Json_Get(main, td, "__cWid")), 1),
		cHei = max(Json_Int(main, Json_Get(main, td, "__cHei")), 1),
	}
}

// A tile's rectangle in its tileset's picture
@(private="file")
rTileSrc :: proc(t: RulesTileset, id: int) -> skald.Rect {
	cx, cy := id % t.cWid, id / t.cWid
	return {t.padding + f32(cx) * (t.grid + t.spacing), t.padding + f32(cy) * (t.grid + t.spacing), t.grid, t.grid}
}

/*
The tileset the rules' tiles come from: the selected level's layer instance's (LDtk's
getTilesetUid: its override), else the layer's.
*/
@(private="file")
rLayerTileset :: proc(c: ^LDtkTabCtx, layerUid, layer: int) -> int {
	if c.level >= 0 {
		if file, li := ruleLayerInstance(c.doc, c.levelIid, layerUid); li >= 0 {
			json := LDtkDoc_Json(c.doc, file)
			if o := nodeUid(json, Json_Get(json, li, "overrideTilesetUid")); o >= 0 do return o
		}
	}
	return nodeUid(c.main, Json_Get(c.main, layer, "tilesetDefUid"))
}

// A tile drawn as a little picture (its tileset's image, `px` wide), or nothing
@(private="file")
rTileView :: proc(c: ^LDtkTabCtx, t: RulesTileset, ids: []int, px: f32, stamp := false) -> skald.View {
	Paint :: struct {
		t: RulesTileset,
		ids: []int,
		stamp: bool,
	}
	p := new(Paint, context.temp_allocator)
	p^ = {t = t, ids = slice.clone(ids, context.temp_allocator), stamp = stamp}
	w, h := px, px
	if stamp && len(ids) > 0 {
		// A stamp: its bounds, scaled to fit
		x0, y0, x1, y1 := 1 << 30, 1 << 30, -1, -1
		for id in ids {
			cx, cy := id % t.cWid, id / t.cWid
			x0, y0, x1, y1 = min(x0, cx), min(y0, cy), max(x1, cx), max(y1, cy)
		}
		cols, rows := x1 - x0 + 1, y1 - y0 + 1
		scale := px / f32(max(cols, rows))
		w, h = f32(cols) * scale, f32(rows) * scale
	}
	return skald.canvas(c.ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		r, b := painter.r, painter.bounds
		skald.draw_rect(r, b, {0, 0, 0, 0.25}, 2)
		if !p.t.ok || len(p.ids) == 0 do return
		if !p.stamp {
			skald.draw_image_region(r, p.t.path, b, rTileSrc(p.t, p.ids[0]), inset = false)
			return
		}
		x0, y0 := 1 << 30, 1 << 30
		cols, rows := 1, 1
		{
			x1, y1 := -1, -1
			for id in p.ids {
				cx, cy := id % p.t.cWid, id / p.t.cWid
				x0, y0, x1, y1 = min(x0, cx), min(y0, cy), max(x1, cx), max(y1, cy)
			}
			cols, rows = x1 - x0 + 1, y1 - y0 + 1
		}
		cw := b.w / f32(cols)
		for id in p.ids {
			cx, cy := id % p.t.cWid - x0, id / p.t.cWid - y0
			skald.draw_image_region(r, p.t.path, {b.x + f32(cx) * cw, b.y + f32(cy) * cw, cw, cw}, rTileSrc(p.t, id), inset = false)
		}
	}, width = w, height = h)
}

// --- The tile picker -----------------------------------------------------------------------------

// A picker's drag (by its key): the first cell pressed, the button, Shift
@(private="file")
RulesPick :: struct {
	dragging, right, shift: bool,
	start: [2]int,
}

@(private="file", thread_local)
rulesPicks: map[string]RulesPick

// Frees the tab's view state (tests, quitting)
LDtkRules_Destroy :: proc() {
	for k in rulesPicks do delete(k)
	delete(rulesPicks)
	rulesPicks = nil
	rulesDrag = {}
	patternDrag = {}
}

// What a pick gave: the tiles of the rectangle dragged (LDtk's order: column by column), how
@(private="file")
RulesPicked :: struct {
	picked: bool,
	ids: []int,
	// The rectangle's corners (cells)
	box: [4]int,
	shift, right: bool,
}

/*
A tileset drawn for picking (LDtk's ui.Tileset): fitted to the tab's width, the tiles `selected`
outlined, `marked` ones filled (`markColor`; `marked2` with `markColor2`), a drag picks a
rectangle of cells: `ids` column by column as LDtk lists them (Tileset.onMouseUp). It zooms and
pans in its box as the canvas does (tile_zoom.odin; the − / + / Fit buttons over it,
`ldtk-<key>-zoom-in`...), its zoom kept per tileset.
*/
@(private="file")
rTilePicker :: proc(c: ^LDtkTabCtx, key: string, t: RulesTileset, selected: []int, marked: []int = nil, markColor: u32 = 0, marked2: []int = nil, markColor2: u32 = 0, maxHeight: f32 = 300) -> (skald.View, RulesPicked) {
	ctx := c.ctx
	th := ctx.theme
	if !t.ok do return uiText(th, .Muted, "The tileset's image can't be read (or the layer has no tileset).", max_width = c.rowWidth, color = th.color.warning), {}
	zoom := min(c.rowWidth / max(t.size.x, 1), 3)
	if t.size.y * zoom > maxHeight do zoom = maxHeight / max(t.size.y, 1)
	zoom = max(zoom, 0.25)
	pickerKey := fmt.tprintf("ldtk-%s", key)
	id := skald.hash_id(pickerKey)
	// The view is the size the tileset fits at that zoom; it zooms and pans in it (tile_zoom.odin)
	zoomKey := TileZoom_Key("picker", t.uid, c.file)
	zi := tileZoomInput(ctx, c.s, zoomKey, id, t.size)
	TileZoom_Record(pickerKey, {t = zi.t, zoom = TileZoom_Get(c.s, zoomKey), grid = t.grid, spacing = t.spacing, padding = t.padding, cWid = t.cWid})
	drag, has := &rulesPicks[pickerKey]
	if !has {
		rulesPicks[strings.clone(pickerKey)] = {}
		drag = &rulesPicks[pickerKey]
	}
	picked: RulesPicked
	if zi.hovered && !zi.panning && (ctx.input.mouse_pressed[.Left] || ctx.input.mouse_pressed[.Right]) && !drag.dragging {
		if cell, on := TileZoom_CellAt(zi.t, ctx.input.mouse_pos, t.grid, t.spacing, t.padding, t.cWid, t.cHei); on do drag^ = {dragging = true, right = !ctx.input.mouse_pressed[.Left], shift = .Shift in ctx.input.modifiers, start = cell}
	}
	box: [4]int
	if drag.dragging {
		cell, _ := TileZoom_CellAt(zi.t, ctx.input.mouse_pos, t.grid, t.spacing, t.padding, t.cWid, t.cHei)
		box = {min(drag.start.x, cell.x), min(drag.start.y, cell.y), max(drag.start.x, cell.x), max(drag.start.y, cell.y)}
		if !ctx.input.mouse_buttons[.Left] && !ctx.input.mouse_buttons[.Right] {
			ids := make([dynamic]int, context.temp_allocator)
			for cx in box[0] ..= box[2] do for cy in box[1] ..= box[3] do append(&ids, cx + cy * t.cWid)
			picked = {picked = true, ids = ids[:], box = box, shift = drag.shift || .Shift in ctx.input.modifiers, right = drag.right}
			drag.dragging = false
		} else {
			skald.send(ctx, Msg(Frame_Requested{}))
		}
	}
	Paint :: struct {
		t: RulesTileset,
		zoom: TileZoom,
		selected, marked, marked2: []int,
		markColor, markColor2, accent: skald.Color,
		dragging: bool,
		box: [4]int,
	}
	p := new(Paint, context.temp_allocator)
	p^ = {t = t, zoom = TileZoom_Get(c.s, zoomKey), selected = slice.clone(selected, context.temp_allocator), marked = slice.clone(marked, context.temp_allocator),
		marked2 = slice.clone(marked2, context.temp_allocator), markColor = skald.rgb(markColor), markColor2 = skald.rgb(markColor2),
		accent = th.color.primary, dragging = drag.dragging, box = box}
	canvas := skald.canvas(ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		r, b := painter.r, painter.bounds
		tf := TileZoom_Transform(p.zoom, p.t.size, b)
		skald.push_clip(r, b)
		defer skald.pop_clip(r)
		TileZoom_DrawImage(r, b, tf, p.t.path, p.t.size)
		cell :: proc(p: ^Paint, tf: TileZoomTransform, id: int) -> skald.Rect {
			return TileZoom_ScreenRect(tf, rTileSrc(p.t, id))
		}
		for id in p.marked {
			c := cell(p, tf, id)
			skald.draw_rect(r, c, {p.markColor.r, p.markColor.g, p.markColor.b, 0.35})
			skald.draw_rect_outline(r, c, 2, p.markColor)
		}
		for id in p.marked2 {
			c := cell(p, tf, id)
			skald.draw_rect(r, c, {p.markColor2.r, p.markColor2.g, p.markColor2.b, 0.35})
			skald.draw_rect_outline(r, c, 2, p.markColor2)
		}
		for id in p.selected {
			c := cell(p, tf, id)
			skald.draw_rect_outline(r, {c.x - 1, c.y - 1, c.w + 2, c.h + 2}, 1, {0, 0, 0, 0.8})
			skald.draw_rect_outline(r, c, 2, p.accent)
		}
		if p.dragging {
			a := cell(p, tf, p.box[0] + p.box[1] * p.t.cWid)
			z := cell(p, tf, p.box[2] + p.box[3] * p.t.cWid)
			skald.draw_rect_outline(r, {a.x, a.y, z.x + z.w - a.x, z.y + z.h - a.y}, 2, {1, 1, 1, 0.9})
		}
	}, id = id, width = t.size.x * zoom, height = t.size.y * zoom, cursor = zi.cursor)
	return skald.col(tileZoomControls(ctx, c.s, zoomKey, pickerKey, t.size), canvas, spacing = uiTokens(ctx).rowGap), picked
}

// LDtk's selection of individual tiles (Tileset.modifySelection, MultipleIndividuals): a drag
// replaces, Shift adds (in tile order), the right button removes (at least one stays)
@(private="file")
rIndividuals :: proc(current: []int, picked: RulesPicked) -> []int {
	if picked.right {
		out := make([dynamic]int, context.temp_allocator)
		append(&out, ..current)
		i := 0
		for i < len(out) && len(out) > 1 {
			if slice.contains(picked.ids, out[i]) do ordered_remove(&out, i)
			else do i += 1
		}
		return out[:]
	}
	if !picked.shift do return picked.ids
	all := make([dynamic]int, context.temp_allocator)
	append(&all, ..current)
	for id in picked.ids do if !slice.contains(all[:], id) do append(&all, id)
	slice.sort(all[:])
	return all[:]
}

// --- The list ------------------------------------------------------------------------------------

// A rule's or group's grip being dragged (view state: the release sends the move)
@(private="file")
RulesDrag :: struct {
	active, group: bool,
	uid: int,
	fromGroup, fromIndex: int,
	// Where it goes: the group (its index) and the place in it
	toGroup, toIndex: int,
}
@(private="file", thread_local)
rulesDrag: RulesDrag

// The source layer's IntGrid values and groups as the palette and pattern show them
@(private="file")
RulesValue :: struct {
	value, group: int,
	name: string,
	color: skald.Color,
}

@(private="file")
RulesGroup :: struct {
	uid: int,
	name: string,
	color: skald.Color,
	hasColor: bool,
}

@(private="file")
rSourceValues :: proc(c: ^LDtkTabCtx, layer: int) -> (values: []RulesValue, groups: []RulesGroup) {
	_, _, source := LDtkRules_SourceValues(c.doc, layer)
	main := c.main
	vs := make([dynamic]RulesValue, context.temp_allocator)
	gs := make([dynamic]RulesGroup, context.temp_allocator)
	for v in Json_Items(main, Json_Get(main, source, "intGridValues")) {
		col, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, v, "color")))
		append(&vs, RulesValue{Json_Int(main, Json_Get(main, v, "value")), Json_Int(main, Json_Get(main, v, "groupUid")), Json_String(main, Json_Get(main, v, "identifier")), skald.rgb(u32(col))})
	}
	for g in Json_Items(main, Json_Get(main, source, "intGridValuesGroups")) {
		col, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, g, "color")))
		uid := Json_Int(main, Json_Get(main, g, "uid"))
		name := Json_String(main, Json_Get(main, g, "identifier"))
		append(&gs, RulesGroup{uid, name != "" ? name : fmt.tprintf("Group %d", uid), skald.rgb(u32(col)), ok})
	}
	return vs[:], gs[:]
}

// A pattern value's name (LDtk's explanations)
@(private="file")
rValueName :: proc(values: []RulesValue, groups: []RulesGroup, v: int) -> string {
	a := abs(v)
	if a == LDTK_ANYTHING do return "any IntGrid value"
	if a > 999 {
		uid := a / 1000 - 1
		if uid == 0 do return "any ungrouped value"
		for g in groups do if g.uid == uid do return fmt.tprintf("any value of the group %s", g.name)
		return fmt.tprintf("the lost group %d", uid)
	}
	for x in values do if x.value == a do return x.name != "" ? fmt.tprintf("\"%s\" (%d)", x.name, a) : fmt.tprintf("value %d", a)
	return fmt.tprintf("the lost value %d", a)
}

// A pattern cell's look (RulePatternEditor's classes)
@(private="file")
rCellColor :: proc(values: []RulesValue, groups: []RulesGroup, v: int) -> (fill: skald.Color, known: bool) {
	a := abs(v)
	if a == LDTK_ANYTHING do return {0.75, 0.75, 0.75, 1}, true
	if a > 999 {
		uid := a / 1000 - 1
		for g in groups do if g.uid == uid do return g.hasColor ? g.color : skald.Color{0.55, 0.55, 0.6, 1}, true
		return {0.55, 0.55, 0.6, 1}, uid == 0
	}
	for x in values do if x.value == a do return x.color, true
	return {1, 0, 1, 1}, false
}

// Draws a pattern cell (shared by the list's previews, the editor's grid, the Assistant's)
@(private="file")
rDrawCell :: proc(r: ^skald.Renderer, rect: skald.Rect, v: int, values: []RulesValue, groups: []RulesGroup, empty: skald.Color) {
	if v == 0 {
		skald.draw_rect(r, rect, empty)
		return
	}
	fill, known := rCellColor(values, groups, v)
	if v == -LDTK_ANYTHING {
		// "Nothing": dark, a ring with a slash
		skald.draw_rect(r, rect, {0.12, 0.12, 0.14, 1})
		c := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		rad := min(rect.w, rect.h) * 0.3
		if rad >= 2 {
			skald.draw_ring(r, c, rad, max(rad * 0.25, 1), {1, 0.35, 0.35, 1})
			skald.draw_line(r, c + {-rad, rad} * 0.7, c + {rad, -rad} * 0.7, max(rad * 0.25, 1), {1, 0.35, 0.35, 1}, aa = true)
		}
		return
	}
	skald.draw_rect(r, rect, fill)
	if !known do skald.draw_rect_outline(r, rect, 2, {1, 0, 1, 1})
	if abs(v) > 999 && abs(v) != LDTK_ANYTHING {
		// A group: an inner outline
		skald.draw_rect_outline(r, {rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4}, 1, {1, 1, 1, 0.7})
	}
	if abs(v) == LDTK_ANYTHING && rect.w >= 6 {
		skald.draw_circle(r, {rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}, min(rect.w, rect.h) * 0.15, {0.3, 0.3, 0.3, 1}, aa = true)
	}
	if v < 0 {
		// "Not": a red cross
		w := max(min(rect.w, rect.h) * 0.12, 1)
		skald.draw_line(r, {rect.x + rect.w * 0.2, rect.y + rect.h * 0.2}, {rect.x + rect.w * 0.8, rect.y + rect.h * 0.8}, w, {0.9, 0.1, 0.1, 1}, aa = true)
		skald.draw_line(r, {rect.x + rect.w * 0.8, rect.y + rect.h * 0.2}, {rect.x + rect.w * 0.2, rect.y + rect.h * 0.8}, w, {0.9, 0.1, 0.1, 1}, aa = true)
	}
}

/*
The list: LDtk's panel header, then each group and (opened) its rules.
*/
@(private="file")
rulesList :: proc(c: ^LDtkTabCtx, layerUid, layer: int) {
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	tk := uiTokens(ctx)
	main := c.main
	usable, why := LDtkRules_CanBeUsed(main, layer)
	groups := LDtkRules_ReadGroups(main, layer)
	if !usable {
		// LDtk's "The current layer settings prevent its rules to work."
		tabNote(c, fmt.tprintf("The current layer settings prevent its rules to work: %s.", why), true)
		rButtons(c, rButton(c, "ldtk-rules-settings", "Open the layer's settings", Msg(Bottom_Tab_Picked(BottomTab.Layers))))
		for g in groups do tabNote(c, fmt.tprintf("\"%s\": %d rule%s", g.name, len(g.rules), len(g.rules) == 1 ? "" : "s"))
		LevelRules_SetHovered(-1, -1, -1)
		return
	}
	values, intGroups := rSourceValues(c, layer)
	knownValues := make(map[int]bool, context.temp_allocator)
	knownGroups := make(map[int]bool, context.temp_allocator)
	for v in values do knownValues[v.value] = true
	for g in intGroups do knownGroups[g.uid] = true
	tsUid := rLayerTileset(c, layerUid, layer)
	ts := rTileset(c, tsUid)

	// The toolbar row: + Group, Paste, Randomize, Render
	addKey := "ldtk-rules-add-group"
	addId := skald.hash_id(addKey)
	tabTool(c, addKey, ACTION_ICONS[.Add], "A new group of rules: with the Assistant, or empty", Msg(Frame_Requested{}), label = "Group")
	if rHovered(ctx, addId) && ctx.input.mouse_released[.Left] {
		r := lastRect(ctx, addId)
		skald.send(ctx, Msg(Context_Menu_Opened{at = {r.x, r.y + r.h}, target = Ctx_Rules_New{layer = layerUid}}))
	}
	if s.level.rules.clipKind == .Group {
		paste := rEdit(c, .Rule_Pasted, layerUid)
		paste.key, paste.text = "group", strings.clone(s.level.rules.clip, context.temp_allocator)
		tabTool(c, "ldtk-rules-paste-group", ACTION_ICONS[.Copy], "Paste the group copied (LDtk's clipboard), at the end", Msg(paste), label = "Paste group")
	}
	seed := rEdit(c, .Rule_Seed, layerUid)
	seed.number = -1
	tabTool(c, "ldtk-rules-randomize", ACTION_ICONS[.Randomize], "A new random seed for this layer in the selected level: rules with a chance or a Perlin filter change", Msg(seed), label = "Randomize", disabled = c.level < 0)
	tabTool(c, "ldtk-rules-render", s.level.paint.hideAutoLayers ? ICON_EYE_SLASH : ICON_EYE, fmt.tprintf("Show the auto-layers' tiles (else their IntGrid values) %s", keyParen(s, .Level_Auto_Layers)),
		Msg(Action.Level_Auto_Layers), label = "Render", on = !s.level.paint.hideAutoLayers)
	// The level's tileset: one of the same size (LDtk's per-instance override)
	if c.level >= 0 && ts.uid >= 0 {
		labels := make([dynamic]string, context.temp_allocator)
		vals := make([dynamic]string, context.temp_allocator)
		defUid := nodeUid(main, Json_Get(main, layer, "tilesetDefUid"))
		for td in Json_Items(main, LDtkDoc_Defs(c.doc, "tilesets")) {
			uid := Json_Int(main, Json_Get(main, td, "uid"))
			compatible := Json_Int(main, Json_Get(main, td, "__cWid")) == ts.cWid && Json_Int(main, Json_Get(main, td, "__cHei")) == ts.cHei && f32(Json_Int(main, Json_Get(main, td, "tileGridSize"))) == ts.grid
			if !compatible do continue
			name := Json_String(main, Json_Get(main, td, "identifier"))
			append(&labels, uid == defUid ? fmt.tprintf("%s (default)", name) : name)
			append(&vals, fmt.tprint(uid))
		}
		Pick :: struct { edit: LDtk_Edit }
		edit := rEdit(c, .Rule_Tileset_Here, layerUid)
		choice := labeledSelect(ctx, fmt.tprint(tsUid), labels[:], vals[:], Pick{edit}, proc(p: Pick, v: string) -> Msg {
			e := p.edit
			n, _ := tabParseInt(v)
			e.number = f64(n)
			return e
		}, id = skald.hash_id("ldtk-rules-tileset"), width = c.controlWidth)
		tabRow(c, "Tileset here", choice, fmt.tprintf("The tileset the rules draw with in %s (any of the same size: LDtk's per-level tileset)", s.level.level))
	}
	if len(groups) == 0 {
		tabNote(c, "No rules yet: + Group makes a group with the Assistant (recommended: walls, corners and edges from one value) or an empty one.")
	}

	// The grips' drag: where the dragged group or rule goes
	drag := &rulesDrag
	if drag.active {
		pointer := ctx.input.mouse_pos.y
		if drag.group {
			to := 0
			for g, gi in groups {
				if g.uid == drag.uid do continue
				rr := lastRect(ctx, skald.hash_id(fmt.tprintf("ldtk-group-row-%d", g.uid)))
				if rr.h > 0 && pointer > rr.y + rr.h * 0.5 do to += 1
				_ = gi
			}
			drag.toIndex = to
		} else {
			// The group under the pointer (the last header above it), then the place among its rules
			target := drag.fromGroup
			for g, gi in groups {
				rr := lastRect(ctx, skald.hash_id(fmt.tprintf("ldtk-group-row-%d", g.uid)))
				if rr.h > 0 && pointer >= rr.y do target = gi
			}
			slot := 0
			if target >= 0 && target < len(groups) {
				for x in groups[target].rules {
					if x.uid == drag.uid do continue
					rr := lastRect(ctx, skald.hash_id(fmt.tprintf("ldtk-rule-row-%d", x.uid)))
					if rr.h > 0 && pointer > rr.y + rr.h * 0.5 do slot += 1
				}
			}
			drag.toGroup, drag.toIndex = target, slot
		}
		skald.cursor_request(ctx, .Move)
		if !ctx.input.mouse_buttons[.Left] {
			if drag.group {
				if drag.toIndex != drag.fromIndex {
					move := rEdit(c, .Rule_Group_Moved, layerUid, group = drag.uid)
					move.number = f64(drag.toIndex - drag.fromIndex)
					skald.send(ctx, Msg(move))
				}
			} else if drag.toGroup >= 0 && drag.toGroup < len(groups) && (drag.toGroup != drag.fromGroup || drag.toIndex != drag.fromIndex) {
				move := rEdit(c, .Rule_Moved, layerUid, group = groups[drag.toGroup].uid, rule = drag.uid)
				move.number = f64(drag.toIndex)
				skald.send(ctx, Msg(move))
			}
			drag^ = {}
		} else {
			skald.send(ctx, Msg(Frame_Requested{}))
		}
	}

	atPointer := LevelRules_AtPointer(layerUid)
	hoveredRule, hoveredGroup := -1, -1
	line := skald.col(skald.spacer(0), height = tk.xxs, bg = th.color.primary)
	for &g, gi in groups {
		if drag.active && drag.group && drag.toIndex == gi && drag.fromIndex != gi && drag.toIndex < drag.fromIndex do append(c.rows, line)
		gh := rGroupHeader(c, layerUid, &g, gi, ts, groups[:], atPointer, &hoveredGroup)
		append(c.rows, gh)
		if drag.active && drag.group && drag.toIndex == gi && drag.fromIndex != gi && drag.toIndex > drag.fromIndex do append(c.rows, line)
		if g.usesWizard {
			edit := Rules_View{op = .Assistant, uid = g.uid}
			adv := rEdit(c, .Rule_Group_Set, layerUid, group = g.uid)
			adv.key, adv.flag = "usesWizard", false
			rButtons(c, rButton(c, fmt.tprintf("ldtk-group-wizard-%d", g.uid), fmt.tprintf("%s  Edit rules", ICON_WAND), Msg(edit)),
				skald.tooltip(ctx, rButton(c, fmt.tprintf("ldtk-group-advanced-%d", g.uid), "Switch to advanced mode", Msg(adv)),
					"Edit its rules by hand or add new ones; the Assistant can't edit this group any more (undo brings it back)", id = skald.hash_id(fmt.tprintf("ldtk-group-advanced-%d-tip", g.uid))))
			tabNote(c, "The rules in this group are managed by the Assistant.")
		}
		if !LevelRules_GroupOpen(s, groups[:], g.uid) {
			// A closed group still takes a dragged rule (LDtk's collapsedSortTarget)
			continue
		}
		for &r, ri in g.rules {
			if drag.active && !drag.group && drag.toGroup == gi && drag.toIndex == ri && drag.uid != r.uid do append(c.rows, line)
			append(c.rows, rRuleRow(c, layerUid, &g, gi, &r, ri, ts, values, intGroups, knownValues, knownGroups, atPointer, &hoveredRule))
		}
		if drag.active && !drag.group && drag.toGroup == gi && drag.toIndex >= len(g.rules) - (drag.fromGroup == gi ? 1 : 0) do append(c.rows, line)
		if len(g.rules) == 0 && !g.usesWizard do tabNote(c, "No rules: + adds one.")
	}
	if LevelRules_SetHovered(layerUid, hoveredRule, hoveredGroup) do skald.send(ctx, Msg(Frame_Requested{}))
	if len(atPointer) > 0 do tabNote(c, fmt.tprintf("The cell under the pointer: %d rule%s put tiles there (highlighted).", len(atPointer), len(atPointer) == 1 ? "" : "s"))
}

// A group's header row
@(private="file")
rGroupHeader :: proc(c: ^LDtkTabCtx, layerUid: int, g: ^LDtkGroupEdit, gi: int, ts: RulesTileset, groups: []LDtkGroupEdit, atPointer: []int, hoveredGroup: ^int) -> skald.View {
	tk := uiTokens(c.ctx)
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	uid := g.uid
	open := LevelRules_GroupOpen(s, groups, uid)
	// Applied here: enabled, and in a level, its biomes (LayerInstance.isRuleGroupAppliedHere)
	enabled := g.active && !g.isOptional
	if g.isOptional && c.level >= 0 {
		if file, li := ruleLayerInstance(c.doc, c.levelIid, layerUid); li >= 0 {
			json := LDtkDoc_Json(c.doc, file)
			for u in Json_Items(json, Json_Get(json, li, "optionalRules")) do if Json_Int(json, u) == uid do enabled = true
		}
	}
	// Not applied in the focused level by its biomes (LDtk's notApplied)
	applied := enabled
	if m := LevelPaint_Current(); enabled && m != nil && m.iid == c.levelIid && len(g.biome) > 0 {
		if l := LevelPaint_LayerByDef(m, layerUid); l != nil && gi < len(m.defs[l.def].groups) do applied = LDtkRules_GroupApplied(m, l, &m.defs[l.def].groups[gi])
	}
	fg := applied ? th.color.fg : th.color.fg_muted
	items := make([dynamic]skald.View, context.temp_allocator)
	// The grip
	gripKey := fmt.tprintf("ldtk-group-grip-%d", uid)
	gripId := skald.hash_id(gripKey)
	if rHovered(ctx, gripId) {
		skald.cursor_request(ctx, .Move)
		if ctx.input.mouse_pressed[.Left] && !rulesDrag.active do rulesDrag = {active = true, group = true, uid = uid, fromIndex = gi, toIndex = gi}
	}
	append(&items, skald.tooltip(ctx, rZone(gripKey, skald.col(uiText(th, .Label, ICON_GRIP_LINES), padding = tk.xxs)), "Drag to move the group (its rules run in the list's order)", id = skald.hash_id(fmt.tprintf("%s-tip", gripKey))))
	// The toggle: on / off; an optional group's eye in this level
	toggleKey := fmt.tprintf("ldtk-group-toggle-%d", uid)
	if g.isOptional {
		e := rEdit(c, .Rule_Group_Here, layerUid, group = uid)
		e.flag = !enabled
		tip := c.level >= 0 ? fmt.tprintf("%s this optional group of rules in %s", enabled ? "Disable" : "Enable", s.level.level) : "An optional group is turned on per level: select a level"
		append(&items, rTipButton(c, toggleKey, enabled ? ICON_EYE : ICON_EYE_SLASH, tip, Msg(e), on = enabled, disabled = c.level < 0))
	} else {
		e := rEdit(c, .Rule_Group_Set, layerUid, group = uid)
		e.key, e.flag = "active", !g.active
		append(&items, rTipButton(c, toggleKey, g.active ? ICON_SQUARE_CHECK : ICON_SQUARE, g.active ? "Disable this group of rules" : "Enable this group of rules", Msg(e), on = g.active))
	}
	// The icon
	if g.hasIcon && ts.ok {
		icon := rTileset(c, g.icon[0])
		if icon.ok {
			x, y, w, h := f32(g.icon[1]), f32(g.icon[2]), f32(g.icon[3]), f32(g.icon[4])
			Paint :: struct { path: string, src: skald.Rect }
			p := new(Paint, context.temp_allocator)
			p^ = {icon.path, {x, y, w, h}}
			append(&items, skald.canvas(ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
				skald.draw_image_region(painter.r, p.path, painter.bounds, p.src, inset = false)
			}, width = tk.iconColumn, height = tk.iconColumn * h / max(w, 1)))
		}
	}
	// The name (a click opens or closes the group), or its text field while renamed
	if s.level.rules.renaming == uid {
		e := rEdit(c, .Rule_Group_Set, layerUid, group = uid)
		e.key = "name"
		field := tabTextField(c, fmt.tprintf("ldtk-group-rename-%d", uid), g.name, e, width = min(c.controlWidth, tk.fieldL))
		append(&items, field, rButton(c, fmt.tprintf("ldtk-group-rename-done-%d", uid), ICON_CHECK, Msg(Rules_View{op = .Rename, uid = -1})))
	} else {
		nameKey := fmt.tprintf("ldtk-group-name-%d", uid)
		nameId := skald.hash_id(nameKey)
		count := fmt.tprintf("%d rule%s", len(g.rules), len(g.rules) == 1 ? "" : "s")
		label := skald.row(uiText(th, .Muted, open ? ICON_CHEVRON_DOWN : ICON_ARROW_RIGHT),
			skald.text(g.name, fg, th.font.size_sm, max_width = max(c.rowWidth * 0.4, tk.fieldXS)), uiText(th, .Muted, count),
			spacing = th.spacing.xs, cross_align = .Center)
		if rHovered(ctx, nameId) {
			hoveredGroup^ = uid
			skald.cursor_request(ctx, .Pointer)
			if ctx.input.mouse_pressed[.Left] && ctx.input.mouse_click_count[.Left] >= 2 {
				skald.send(ctx, Msg(Rules_View{op = .Rename, uid = uid}))
			} else if ctx.input.mouse_pressed[.Left] {
				skald.send(ctx, Msg(Rules_View{op = .Group_Open, uid = uid, flag = !open}))
			}
		}
		append(&items, skald.tooltip(ctx, rZone(nameKey, label), "Click to open or close the group (double-click: rename); its rules' cells show on the level", id = skald.hash_id(fmt.tprintf("%s-tip", nameKey))))
	}
	// Biomes
	main := c.main
	if Json_Kind(main, Json_Get(main, Json_Path(main, fmt.tprintf("defs.layers.uid=%d", layerUid)), "biomeFieldUid")) == .Number {
		text := "any biome"
		if len(g.biome) > 0 do text = strings.join(g.biome[:], g.biomeMode == 1 ? " + " : " / ", context.temp_allocator)
		append(&items, uiText(th, .Muted, fmt.tprintf("%s %s", ICON_GLOBE, text), max_width = tk.textNarrow))
	}
	if g.isOptional do append(&items, uiText(th, .Muted, "optional"))
	if enabled && !applied do append(&items, uiText(th, .Muted, "not in this level's biomes", color = th.color.warning))
	if !g.usesWizard {
		add := rEdit(c, .Rule_Added, layerUid, group = uid)
		append(&items, rTipButton(c, fmt.tprintf("ldtk-group-add-%d", uid), ACTION_ICONS[.Add], "A new rule, first in the group", Msg(add)))
	} else {
		append(&items, rTipButton(c, fmt.tprintf("ldtk-group-edit-%d", uid), "EDIT", "Edit the group's rules with the Assistant", Msg(Rules_View{op = .Assistant, uid = uid})))
	}
	menuKey := fmt.tprintf("ldtk-group-menu-%d", uid)
	menuId := skald.hash_id(menuKey)
	append(&items, rTipButton(c, menuKey, ICON_ELLIPSIS, "The group's menu (or right-click it)", Msg(Frame_Requested{})))
	target := Ctx_Rule_Group{layer = layerUid, group = uid}
	if rHovered(ctx, menuId) && ctx.input.mouse_released[.Left] {
		r := lastRect(ctx, menuId)
		skald.send(ctx, Msg(Context_Menu_Opened{at = {r.x, r.y + r.h}, target = target}))
	}
	rowKey := fmt.tprintf("ldtk-group-row-%d", uid)
	rowId := skald.hash_id(rowKey)
	if rHovered(ctx, rowId) && ctx.input.mouse_pressed[.Right] {
		skald.send(ctx, Msg(Context_Menu_Opened{at = ctx.input.mouse_pos, target = target}))
		ctx.input.mouse_pressed[.Right] = false
	}
	bg := th.color.surface
	if g.color >= 0 {
		col := skald.rgb(u32(g.color))
		bg = {col.r, col.g, col.b, 0.7}
	}
	if !applied do bg.a *= 0.5
	// A group with a rule under the canvas's pointer
	for &r in g.rules do if LevelRules_Has(atPointer, r.uid) do bg = th.color.elevated
	if rulesDrag.active && !rulesDrag.group && rulesDrag.toGroup == gi do bg = th.color.elevated
	views := make([]skald.View, len(items), context.temp_allocator)
	copy(views, items[:])
	content := skald.wrap_row(..views, spacing = th.spacing.sm, line_spacing = 2, width = c.rowWidth - th.spacing.sm * 2)
	return rZone(rowKey, skald.col(content, padding = th.spacing.xs, bg = bg, radius = th.radius.sm, width = c.rowWidth))
}

// A rule's row
@(private="file")
rRuleRow :: proc(c: ^LDtkTabCtx, layerUid: int, g: ^LDtkGroupEdit, gi: int, r: ^LDtkRule, ri: int, ts: RulesTileset, values: []RulesValue, groups: []RulesGroup,
	knownValues, knownGroups: map[int]bool, atPointer: []int, hoveredRule: ^int) -> skald.View {
	tk := uiTokens(c.ctx)
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	uid := r.uid
	wizard := g.usesWizard
	items := make([dynamic]skald.View, context.temp_allocator)
	// The grip
	gripKey := fmt.tprintf("ldtk-rule-grip-%d", uid)
	gripId := skald.hash_id(gripKey)
	if !wizard && rHovered(ctx, gripId) {
		skald.cursor_request(ctx, .Move)
		if ctx.input.mouse_pressed[.Left] && !rulesDrag.active do rulesDrag = {active = true, uid = uid, fromGroup = gi, fromIndex = ri, toGroup = gi, toIndex = ri}
	}
	append(&items, rZone(gripKey, skald.col(uiText(th, .Muted, ICON_GRIP_LINES), padding = tk.xxs)))
	toggle := rSet(c, layerUid, uid, "active")
	toggle.flag = !r.active
	append(&items, rTipButton(c, fmt.tprintf("ldtk-rule-toggle-%d", uid), r.active ? ICON_SQUARE_CHECK : ICON_SQUARE, "Enable or disable this rule", Msg(toggle), on = r.active, disabled = wizard))
	// The pattern (a click opens the rule's editor; hovering shows its cells on the level)
	previewKey := fmt.tprintf("ldtk-rule-preview-%d", uid)
	previewId := skald.hash_id(previewKey)
	if rHovered(ctx, previewId) {
		hoveredRule^ = uid
		if !wizard {
			skald.cursor_request(ctx, .Pointer)
			if ctx.input.mouse_released[.Left] do skald.send(ctx, Msg(Rules_View{op = .Edit, uid = uid}))
		}
	}
	append(&items, skald.tooltip(ctx, rZone(previewKey, rPatternPreview(c, r, ts, values, groups, knownValues, knownGroups)),
		wizard ? "Its cells show on the level" : "Click to edit the rule; its cells show on the level", id = skald.hash_id(fmt.tprintf("%s-tip", previewKey))))
	// Chance (a percentage) and opacity
	chance := rSet(c, layerUid, uid, "chance")
	chance.number2 = 100
	append(&items, skald.tooltip(ctx, numberField(ctx, s, fmt.tprintf("ldtk-rule-chance-%d", uid), LDtkNumberTarget{chance}, math.round(r.chance * 1000) / 10, 5, 1, 96, 1, 100),
		"Random probability for this rule to apply (%)", id = skald.hash_id(fmt.tprintf("ldtk-rule-chance-tip-%d", uid))))
	alpha := rSet(c, layerUid, uid, "alpha")
	append(&items, skald.tooltip(ctx, numberField(ctx, s, fmt.tprintf("ldtk-rule-alpha-%d", uid), LDtkNumberTarget{alpha}, r.alpha, 0.05, 2, 96, 0.01, 1),
		"Opacity of the resulting tiles (0.01 to 1)", id = skald.hash_id(fmt.tprintf("ldtk-rule-alpha-tip-%d", uid))))
	flag :: proc(c: ^LDtkTabCtx, layerUid, uid: int, key, label, tip: string, value, disabled: bool) -> skald.View {
		e := rSet(c, layerUid, uid, key)
		e.flag = !value
		return rTipButton(c, fmt.tprintf("ldtk-rule-%s-%d", strings.to_lower(key, context.temp_allocator), uid), label, tip, Msg(e), on = value, disabled = disabled)
	}
	append(&items,
		flag(c, layerUid, uid, "breakOnMatch", ICON_STOP, "Stop on match: when this rule applies in a cell, the rules below don't", r.breakOnMatch, wizard),
		flag(c, layerUid, uid, "flipX", "X", "X mirror: the rule also matches reversed horizontally", r.flipX, wizard),
		flag(c, layerUid, uid, "flipY", "Y", "Y mirror: the rule also matches reversed vertically", r.flipY, wizard),
		rTipButton(c, fmt.tprintf("ldtk-rule-offset-%d", uid), ICON_MOVE, "Tile offsets and random offsets (in the rule's editor)", Msg(Rules_View{op = .Edit, uid = uid}), on = LDtkRule_HasOffset(r), disabled = wizard),
		rTipButton(c, fmt.tprintf("ldtk-rule-modulo-%d", uid), fmt.tprintf("%d-%d", r.xModulo, r.yModulo), "Modulos and checker mode (in the rule's editor)", Msg(Rules_View{op = .Edit, uid = uid}), on = r.xModulo != 1 || r.yModulo != 1, disabled = wizard),
	)
	perlinKey := fmt.tprintf("ldtk-rule-perlin-%d", uid)
	perlin := rSet(c, layerUid, uid, "perlinActive")
	perlin.flag = !r.perlinActive
	if !wizard && rHovered(ctx, skald.hash_id(perlinKey)) && ctx.input.mouse_pressed[.Right] {
		// LDtk's right click: the Perlin settings (and Perlin on)
		if !r.perlinActive do skald.send(ctx, Msg(perlin))
		skald.send(ctx, Msg(Rules_View{op = .Edit, uid = uid}))
		ctx.input.mouse_pressed[.Right] = false
	}
	append(&items, rTipButton(c, perlinKey, "P", "Perlin filtering: the rule applies only where a Perlin noise is positive (right-click: its settings)", Msg(perlin), on = r.perlinActive, disabled = wizard))
	if !wizard {
		before := rEdit(c, .Rule_Added, layerUid, group = g.uid)
		before.number = f64(ri)
		after := before
		after.number = f64(ri + 1)
		append(&items,
			rTipButton(c, fmt.tprintf("ldtk-rule-before-%d", uid), fmt.tprintf("%s%s", ACTION_ICONS[.Add], ICON_ARROW_UP), "Create a new rule before", Msg(before)),
			rTipButton(c, fmt.tprintf("ldtk-rule-after-%d", uid), fmt.tprintf("%s%s", ACTION_ICONS[.Add], ICON_ARROW_DOWN), "Create a new rule after", Msg(after)))
	}
	rowKey := fmt.tprintf("ldtk-rule-row-%d", uid)
	rowId := skald.hash_id(rowKey)
	if !wizard && rHovered(ctx, rowId) {
		if ctx.input.mouse_pressed[.Left] && s.level.rules.last != uid do skald.send(ctx, Msg(Rules_View{op = .Last, uid = uid}))
		if ctx.input.mouse_pressed[.Right] {
			skald.send(ctx, Msg(Context_Menu_Opened{at = ctx.input.mouse_pos, target = Ctx_Rule{layer = layerUid, group = g.uid, rule = uid}}))
			ctx.input.mouse_pressed[.Right] = false
		}
	}
	bg := skald.Color{}
	if LevelRules_Has(atPointer, uid) do bg = th.color.elevated
	if !r.active do bg = {th.color.bg.r, th.color.bg.g, th.color.bg.b, 0.5}
	views := make([]skald.View, len(items), context.temp_allocator)
	copy(views, items[:])
	content := skald.wrap_row(..views, spacing = th.spacing.xs, line_spacing = 2, width = c.rowWidth - th.spacing.lg)
	row := skald.col(content, padding = tk.xxs, bg = bg, radius = th.radius.sm, width = c.rowWidth)
	if s.level.rules.last == uid {
		// LDtk's last rule: outlined
		row = skald.col(row, padding = tk.hair, bg = th.color.primary, radius = th.radius.sm, width = c.rowWidth)
	}
	return rZone(rowKey, skald.row(skald.spacer(th.spacing.md), row))
}

// A rule's pattern, small (RulePatternEditor's preview: the center shows its first tile)
@(private="file")
rPatternPreview :: proc(c: ^LDtkTabCtx, r: ^LDtkRule, ts: RulesTileset, values: []RulesValue, groups: []RulesGroup, knownValues, knownGroups: map[int]bool) -> skald.View {
	th := c.ctx.theme
	if LDtkRule_UsesUnknownValues(r, knownValues, knownGroups) do return skald.col(uiText(th, .Muted, "Error", color = th.color.danger), width = 40, height = 40, bg = th.color.bg)
	Paint :: struct {
		size: int,
		pattern: []int,
		values: []RulesValue,
		groups: []RulesGroup,
		ts: RulesTileset,
		tile: int,
		multi: bool,
		empty: skald.Color,
	}
	p := new(Paint, context.temp_allocator)
	p^ = {size = r.size, pattern = slice.clone(r.pattern[:], context.temp_allocator), values = values, groups = groups, ts = ts, tile = -1, multi = len(r.tileRectsIds) > 1, empty = th.color.bg}
	if len(r.tileRectsIds) > 0 && len(r.tileRectsIds[0]) > 0 do p.tile = r.tileRectsIds[0][0]
	px := f32(40)
	return skald.canvas(c.ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		rr, b := painter.r, painter.bounds
		skald.draw_rect(rr, b, {0, 0, 0, 0.3})
		cell := b.w / f32(p.size)
		center := p.size / 2
		for cy in 0 ..< p.size do for cx in 0 ..< p.size {
			rect := skald.Rect{b.x + f32(cx) * cell + 0.5, b.y + f32(cy) * cell + 0.5, cell - 1, cell - 1}
			if cx == center && cy == center && p.tile >= 0 && p.ts.ok {
				skald.draw_image_region(rr, p.ts.path, rect, rTileSrc(p.ts, p.tile), inset = false)
				if p.multi do skald.draw_rect_outline(rr, rect, 1, {1, 1, 0, 0.9})
				continue
			}
			rDrawCell(rr, rect, p.pattern[cx + cy * p.size], p.values, p.groups, p.empty)
		}
	}, width = px, height = px)
}

// --- The rule editor ------------------------------------------------------------------------------

// The pattern grid's drag (view state; the release sends the pattern)
@(private="file")
PatternDrag :: struct {
	active: bool,
	rule: int,
	// LDtk's drawButton: 0 left, 1 middle, 2 right; the value of the cell pressed first
	button, start: int,
	grid: [81]int,
	changed: bool,
}
@(private="file", thread_local)
patternDrag: PatternDrag

/*
The rule's editor (LDtk's RuleEditor and the dialogs its row opens): tiles, pattern, value palette,
out-of-bounds policy, then every placement option.
*/
@(private="file")
rulesEditor :: proc(c: ^LDtkTabCtx, layerUid, layer: int) {
	tk := uiTokens(c.ctx)
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	r, g, ok := LevelRules_Rule(c.doc, layer, s.level.rules.rule)
	if !ok {
		skald.send(ctx, Msg(Rules_View{op = .Close}))
		return
	}
	uid := r.uid
	LevelRules_SetHovered(layerUid, uid, -1)
	rButtons(c, rButton(c, "ldtk-rule-close", fmt.tprintf("%s  Back to the rules", ICON_ARROW_LEFT), Msg(Rules_View{op = .Close})),
		rButton(c, "ldtk-rule-help", "Help", Msg(Rules_View{op = .Help, flag = !s.level.rules.help}), on = s.level.rules.help),
		uiText(th, .Muted, fmt.tprintf("Rule #%d of \"%s\"", uid, g.name)))
	if s.level.rules.help do tabNote(c, "A rule draws tiles where the level's IntGrid values match its pattern: for example \"grass\" tiles above every wall. First pick the tile(s) to draw, then paint the pattern (the context in which they're drawn).")
	values, groups := rSourceValues(c, layer)
	tsUid := rLayerTileset(c, layerUid, layer)
	ts := rTileset(c, tsUid)

	// Tiles: the mode, the tiles picked, the tileset
	tabHeading(c, "Tiles")
	modeEdit := rSet(c, layerUid, uid, "tileMode")
	tabRow(c, "Tile mode", tabChoiceField(c, "ldtk-rule-tilemode", r.tileMode == .Stamp ? "Stamp" : "Single", []string{"Individual tiles (random)", "Rectangles of tiles (stamps)"}, []string{"Single", "Stamp"}, modeEdit),
		"Individual tiles: one of them, at random, in each matching cell. Rectangles: a stamp of tiles placed by its pivot (changing the mode clears the tiles)")
	if r.tileMode == .Single {
		current := make([dynamic]int, context.temp_allocator)
		for ids in r.tileRectsIds do if len(ids) > 0 do append(&current, ids[0])
		row := make([dynamic]skald.View, context.temp_allocator)
		for id in current do append(&row, rTileView(c, ts, {id}, 24))
		if len(current) == 0 do append(&row, uiText(th, .Muted, "No tiles yet: pick them on the tileset below (a drag; Shift adds, the right button removes).", max_width = c.rowWidth, color = th.color.warning))
		rButtons(c, ..row[:])
		picker, picked := rTilePicker(c, "rule-tiles", ts, current[:])
		append(c.rows, picker)
		if picked.picked {
			ids := rIndividuals(current[:], picked)
			if len(ids) > 0 {
				e := rEdit(c, .Rule_Tiles, layerUid, rule = uid)
				e.key, e.ids = "single", ids
				skald.send(ctx, Msg(e))
			}
		}
	} else {
		row := make([dynamic]skald.View, context.temp_allocator)
		stamp := s.level.rules.stamp
		for ids, i in r.tileRectsIds {
			key := fmt.tprintf("ldtk-rule-stamp-%d", i)
			id := skald.hash_id(key)
			if rHovered(ctx, id) {
				if ctx.input.mouse_pressed[.Left] do skald.send(ctx, Msg(Rules_View{op = .Stamp, number = i}))
				if ctx.input.mouse_pressed[.Right] || ctx.input.mouse_pressed[.Middle] {
					e := rEdit(c, .Rule_Tiles, layerUid, rule = uid)
					e.key, e.number = "remove", f64(i)
					skald.send(ctx, Msg(e))
					ctx.input.mouse_pressed[.Right] = false
				}
			}
			v := rTileView(c, ts, ids[:], 32, stamp = true)
			if stamp == i do v = skald.col(v, padding = tk.xxs, bg = th.color.primary, radius = th.radius.sm)
			append(&row, skald.tooltip(ctx, rZone(key, v), "Click: the tileset replaces it; right click: remove it", id = skald.hash_id(fmt.tprintf("%s-tip", key))))
		}
		append(&row, rButton(c, "ldtk-rule-stamp-add", fmt.tprintf("%s  Stamp", ACTION_ICONS[.Add]), Msg(Rules_View{op = .Stamp, number = -1}), on = stamp < 0 || stamp >= len(r.tileRectsIds)))
		rButtons(c, ..row[:])
		tabNote(c, stamp >= 0 && stamp < len(r.tileRectsIds) ? fmt.tprintf("A rectangle dragged on the tileset replaces stamp %d.", stamp + 1) : "A rectangle dragged on the tileset adds a stamp (one is picked at random in each matching cell).")
		selected := stamp >= 0 && stamp < len(r.tileRectsIds) ? r.tileRectsIds[stamp][:] : nil
		picker, picked := rTilePicker(c, "rule-tiles", ts, selected)
		append(c.rows, picker)
		if picked.picked && !picked.right {
			e := rEdit(c, .Rule_Tiles, layerUid, rule = uid)
			e.key, e.ids, e.number = "stamp", picked.ids, f64(stamp)
			skald.send(ctx, Msg(e))
		}
		// The stamp's pivot (JsTools.createPivotEditor: nine points)
		pivots := make([dynamic]skald.View, context.temp_allocator)
		for py in 0 ..< 3 {
			line := make([dynamic]skald.View, context.temp_allocator)
			for px in 0 ..< 3 {
				x, y := f64(px) * 0.5, f64(py) * 0.5
				e := rSet(c, layerUid, uid, "pivot")
				e.number, e.number2 = x, y
				on := r.pivot.x == x && r.pivot.y == y
				append(&line, rButton(c, fmt.tprintf("ldtk-rule-pivot-%d-%d", px, py), on ? ICON_CIRCLE_DOT : ICON_CIRCLE, Msg(e), on = on, width = tk.panelButtonWidth))
			}
			append(&pivots, skald.row(..line[:], spacing = tk.xxs))
		}
		tabRow(c, "Stamp pivot", skald.col(..pivots[:], spacing = tk.xxs), "Where the stamp is placed from its matching cell (top left to bottom right)")
	}

	// The pattern and its palette
	tabHeading(c, "Pattern")
	rPalette(c, values, groups)
	explain := rPatternGrid(c, layerUid, &r, values, groups, ts)
	tabNote(c, explain != "" ? explain : "Left button: this value is required; right button: it must NOT be there; middle: clear (\"anything\"). The center is where the tiles are drawn.")
	if s.level.rules.help do tabNote(c, "Use \"Any value / No value\" to match any IntGrid value (left) or no value at all (right). For example, to draw wall blocks where the level has value 1, put 1 at the center: \"if a cell holds 1, draw the tiles there\".")
	// The out-of-bounds policy (JsTools.createOutOfBoundsRulePolicy)
	oobLabels := make([dynamic]string, context.temp_allocator)
	oobValues := make([dynamic]string, context.temp_allocator)
	append(&oobLabels, "Doesn't apply past the layer's edges (default)", "Empty cells")
	append(&oobValues, "", "0")
	for v in values {
		append(&oobLabels, v.name != "" ? fmt.tprintf("%d - %s", v.value, v.name) : fmt.tprint(v.value))
		append(&oobValues, fmt.tprint(v.value))
	}
	oob := r.hasOutOfBounds ? fmt.tprint(r.outOfBounds) : ""
	tabRow(c, "Out of bounds", tabChoiceField(c, "ldtk-rule-oob", oob, oobLabels[:], oobValues[:], rSet(c, layerUid, uid, "outOfBoundsValue")),
		"The IntGrid value this rule reads in cells outside the layer: by default it doesn't apply where its pattern reaches past the level's edges")

	// The options (the row's and LDtk's dialogs')
	tabHeading(c, "Placement")
	num :: proc(c: ^LDtkTabCtx, layerUid, uid: int, label, key, tip: string, value, step: f64, decimals: int, lo, hi: f64, percent := false) {
		e := rSet(c, layerUid, uid, key)
		if percent do e.number2 = 100
		tabNumberRow(c, label, fmt.tprintf("ldtk-rule-%s", key), tip, e, percent ? math.round(value * 1000) / 10 : value, step, decimals, lo, hi)
	}
	flag :: proc(c: ^LDtkTabCtx, layerUid, uid: int, label, key, tip: string, value: bool) {
		e := rSet(c, layerUid, uid, key)
		tabFlagRow(c, label, fmt.tprintf("ldtk-rule-%s", key), tip, e, value)
	}
	num(c, layerUid, uid, "Chance (%)", "chance", "Random probability for this rule to apply in a matching cell", r.chance, 5, 1, 1, 100, percent = true)
	num(c, layerUid, uid, "Opacity", "alpha", "The opacity of the tiles it draws (0.01 to 1)", r.alpha, 0.05, 2, 0.01, 1)
	flag(c, layerUid, uid, "Break on match", "breakOnMatch", "When this rule applies in a cell, the rules below it don't", r.breakOnMatch)
	flag(c, layerUid, uid, "X mirror", "flipX", "The rule also matches its pattern reversed horizontally (no effect on a symmetric pattern)", r.flipX)
	flag(c, layerUid, uid, "Y mirror", "flipY", "The rule also matches its pattern reversed vertically (no effect on a symmetric pattern)", r.flipY)

	// Modulos (RuleModuloEditor)
	tabHeading(c, "Modulos")
	num(c, layerUid, uid, "X modulo", "xModulo", "Apply the rule only every X columns", f64(r.xModulo), 1, 0, 1, 40)
	num(c, layerUid, uid, "X offset", "xOffset", "Shifts the columns the X modulo counts", f64(r.xOffset), 1, 0, -4096, 4096)
	num(c, layerUid, uid, "Y modulo", "yModulo", "Apply the rule only every Y rows", f64(r.yModulo), 1, 0, 1, 40)
	num(c, layerUid, uid, "Y offset", "yOffset", "Shifts the rows the Y modulo counts", f64(r.yOffset), 1, 0, -4096, 4096)
	checkerLabels := make([dynamic]string, context.temp_allocator)
	checkerValues := make([dynamic]string, context.temp_allocator)
	append(&checkerLabels, "Off")
	append(&checkerValues, "None")
	if r.xModulo > 1 {
		append(&checkerLabels, "Horizontally")
		append(&checkerValues, "Horizontal")
	}
	if r.yModulo > 1 {
		append(&checkerLabels, "Vertically")
		append(&checkerValues, "Vertical")
	}
	checker := "None"
	switch r.checker {
	case .None:
	case .Horizontal: checker = "Horizontal"
	case .Vertical: checker = "Vertical"
	}
	tabRow(c, "Checkerboard", tabChoiceField(c, "ldtk-rule-checker", checker, checkerLabels[:], checkerValues[:], rSet(c, layerUid, uid, "checker")),
		"Alternates the tiles like a checkerboard: every other row (or column) shifted by half the modulo")
	reset := rSet(c, layerUid, uid, "moduloReset")
	rButtons(c, rButton(c, "ldtk-rule-modulo-reset", "Reset modulos", Msg(reset), disabled = r.xModulo == 1 && r.yModulo == 1 && r.xOffset == 0 && r.yOffset == 0))
	append(c.rows, rModuloPreview(c, &r))

	// Offsets (RuleRandomOffsets)
	tabHeading(c, "Offsets")
	num(c, layerUid, uid, "Tile X offset", "tileXOffset", "Moves the tiles it draws sideways (pixels)", f64(r.tileXOffset), 1, 0, -1024, 1024)
	num(c, layerUid, uid, "Tile Y offset", "tileYOffset", "Moves the tiles it draws up or down (pixels)", f64(r.tileYOffset), 1, 0, -1024, 1024)
	randomAxis :: proc(c: ^LDtkTabCtx, layerUid, uid: int, axis: string, lo, hi: int, unlinked: bool) {
		tk := uiTokens(c.ctx)
		s := c.s
		link := Rules_View{op = axis == "X" ? .Unlink_X : .Unlink_Y, flag = !unlinked}
		linkButton := rTipButton(c, fmt.tprintf("ldtk-rule-link-%s", strings.to_lower(axis, context.temp_allocator)), unlinked ? ICON_LINK_SLASH : ICON_LINK,
			unlinked ? "Link min and max (-max to max)" : "Unlink min and max", Msg(link), on = !unlinked)
		if !unlinked {
			e := rSet(c, layerUid, uid, fmt.tprintf("tileRandom%s", axis))
			tabRow(c, fmt.tprintf("Random %s", axis), skald.row(numberField(c.ctx, s, fmt.tprintf("ldtk-rule-tileRandom%s", axis), LDtkNumberTarget{e}, f64(hi), 1, 0, 120, 0, 1024), linkButton, spacing = tk.xs, cross_align = .Center),
				fmt.tprintf("Tiles move at random by up to this many pixels %s either way (-max to max)", axis == "X" ? "sideways" : "up or down"))
			return
		}
		mn := rSet(c, layerUid, uid, fmt.tprintf("tileRandom%sMin", axis))
		mx := rSet(c, layerUid, uid, fmt.tprintf("tileRandom%sMax", axis))
		tabRow(c, fmt.tprintf("Random %s", axis), skald.wrap_row(numberField(c.ctx, s, fmt.tprintf("ldtk-rule-tileRandom%sMin", axis), LDtkNumberTarget{mn}, f64(lo), 1, 0, 96, -1024, 1024),
			numberField(c.ctx, s, fmt.tprintf("ldtk-rule-tileRandom%sMax", axis), LDtkNumberTarget{mx}, f64(hi), 1, 0, 96, -1024, 1024), linkButton, spacing = tk.xs, width = c.controlWidth),
			"Tiles move at random by a number of pixels from min to max")
	}
	randomAxis(c, layerUid, uid, "X", r.tileRandomXMin, r.tileRandomXMax, s.level.rules.unlinkX)
	// Linked but not -max to max any more (an undo, LDtk): shown unlinked
	if !s.level.rules.unlinkX && r.tileRandomXMin != -r.tileRandomXMax do skald.send(ctx, Msg(Rules_View{op = .Unlink_X, flag = true}))
	randomAxis(c, layerUid, uid, "Y", r.tileRandomYMin, r.tileRandomYMax, s.level.rules.unlinkY)
	if !s.level.rules.unlinkY && r.tileRandomYMin != -r.tileRandomYMax do skald.send(ctx, Msg(Rules_View{op = .Unlink_Y, flag = true}))
	rButtons(c, rButton(c, "ldtk-rule-offsets-reset", fmt.tprintf("%s  Reset all offsets", ACTION_ICONS[.Reset]), Msg(rSet(c, layerUid, uid, "offsetsReset")), disabled = !LDtkRule_HasOffset(&r)))

	// Perlin (RulePerlinSettings)
	tabHeading(c, "Perlin filter")
	flag(c, layerUid, uid, "Perlin", "perlinActive", "The rule applies only where a Perlin noise is positive (random areas)", r.perlinActive)
	if r.perlinActive {
		num(c, layerUid, uid, "Seed", "perlinSeed", "The noise's seed", f64(r.perlinSeed), 1, 0, -2147483648, 2147483647)
		random := rSet(c, layerUid, uid, "perlinSeedRandom")
		num(c, layerUid, uid, "Scale (%)", "perlinScale", "The noise's scale: smaller makes bigger areas", r.perlinScale, 1, 0, 1, 99, percent = true)
		num(c, layerUid, uid, "Octaves", "perlinOctaves", "The noise's detail (1 to 4)", f64(r.perlinOctaves), 1, 0, 1, 4)
		preview := skald.checkbox(ctx, s.level.rules.perlinPreview, "Show the noise on the level", 0, proc(_: int, v: bool) -> Msg { return Msg(Rules_View{op = .Perlin_Preview, flag = v}) }, id = skald.hash_id("ldtk-rule-perlin-preview"))
		rButtons(c, rTipButton(c, "ldtk-rule-perlin-random", fmt.tprintf("%s  Random seed", ACTION_ICONS[.Randomize]), "A new random seed for the noise", Msg(random)), preview)
	}
	// Its menu's commands
	dup := rEdit(c, .Rule_Duplicated, layerUid, rule = uid)
	del := rEdit(c, .Rule_Removed, layerUid, rule = uid)
	tabHeading(c, "Rule")
	rButtons(c, rButton(c, "ldtk-rule-copy", fmt.tprintf("%s  Copy", ACTION_ICONS[.Copy]), Msg(Rules_View{op = .Copy, uid = g.uid, number = uid})),
		rButton(c, "ldtk-rule-duplicate", "Duplicate", Msg(dup)),
		rButton(c, "ldtk-rule-delete", fmt.tprintf("%s  Delete", ACTION_ICONS[.Delete]), Msg(del)))
}

// The palette of the rule editor's values (RuleEditor.updateValuePalette)
@(private="file")
rPalette :: proc(c: ^LDtkTabCtx, values: []RulesValue, groups: []RulesGroup) {
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	current := s.level.rules.value
	chip :: proc(c: ^LDtkTabCtx, key, label: string, color: skald.Color, value: int, on: bool) -> skald.View {
		tk := uiTokens(c.ctx)
		th := c.ctx.theme
		lum := 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
		fg := lum > 0.55 ? skald.Color{0, 0, 0, 1} : skald.Color{1, 1, 1, 1}
		b := skald.button(c.ctx, label, Msg(Rules_View{op = .Value, number = value}), id = skald.hash_id(key), bg = color, fg = fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
		if on do return skald.col(b, padding = tk.xxs, bg = th.color.primary, radius = th.radius.sm)
		return skald.col(b, padding = tk.xxs)
	}
	order := make([dynamic]int, context.temp_allocator)
	append(&order, 0)
	for g in groups do append(&order, g.uid)
	for gid in order {
		items := make([dynamic]skald.View, context.temp_allocator)
		count := 0
		for v in values do if v.group == gid do count += 1
		if count == 0 do continue
		if len(groups) > 0 {
			name := "Ungrouped"
			color := skald.Color{0.4, 0.4, 0.45, 1}
			for g in groups do if g.uid == gid {
				name = g.name
				if g.hasColor do color = g.color
			}
			value := (gid + 1) * 1000
			append(&items, skald.tooltip(ctx, chip(c, fmt.tprintf("ldtk-rule-group-%d", gid), fmt.tprintf("%s %s", ICON_FOLDER, name), color, value, current == value),
				"Any value of this group", id = skald.hash_id(fmt.tprintf("ldtk-rule-group-%d-tip", gid))))
		}
		for v in values do if v.group == gid {
			append(&items, chip(c, fmt.tprintf("ldtk-rule-value-%d", v.value), v.name != "" ? fmt.tprintf("%d %s", v.value, v.name) : fmt.tprint(v.value), v.color, v.value, current == v.value))
		}
		rButtons(c, ..items[:])
	}
	rButtons(c, skald.tooltip(ctx, chip(c, "ldtk-rule-value-any", "\"Any value\" / \"No value\"", {0.75, 0.75, 0.75, 1}, LDTK_ANYTHING, current == LDTK_ANYTHING),
		"Left button: any IntGrid value; right button: no value at all", id = skald.hash_id("ldtk-rule-value-any-tip")))
	_ = th
}

/*
The pattern grid (RulePatternEditor, editable): 9 x 9 cells, the rule's pattern centered in it;
LDtk's buttons on a press and as the pointer moves while held (the pattern sent on the release).

Returns:
- The explanation of the cell under the pointer (LDtk's explainCell), "" none
*/
@(private="file")
rPatternGrid :: proc(c: ^LDtkTabCtx, layerUid: int, r: ^LDtkRule, values: []RulesValue, groups: []RulesGroup, ts: RulesTileset) -> string {
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	N :: LDTK_MAX_PATTERN_SIZE
	grid: [81]int
	pad := (N - r.size) / 2
	for cy in 0 ..< r.size do for cx in 0 ..< r.size do grid[cx + pad + (cy + pad) * N] = r.pattern[cx + cy * r.size]
	drag := &patternDrag
	if drag.active && drag.rule == r.uid do grid = drag.grid
	// It's indented as a control under its label: what's left of the row beside the label column
	available := c.stacked ? c.rowWidth : c.rowWidth - LDTK_LABEL_WIDTH
	cellPx := clamp((min(available, 360) - 4) / N, 14, 34)
	key := "ldtk-rule-pattern"
	id := skald.hash_id(key)
	cellAt :: proc(ctx: ^skald.Ctx(Msg), id: skald.Widget_ID, cellPx: f32) -> ([2]int, bool) {
		st, ok := ctx.widgets.states[id]
		if !ok do return {}, false
		rr := st.last_rect
		local := ctx.input.mouse_pos - {rr.x, rr.y}
		cx, cy := int(math.floor(local.x / cellPx)), int(math.floor(local.y / cellPx))
		return {cx, cy}, cx >= 0 && cy >= 0 && cx < N && cy < N
	}
	explain := ""
	cell, inside := cellAt(ctx, id, cellPx)
	hovered := rHovered(ctx, id) && inside
	if hovered {
		v := grid[cell.x + cell.y * N]
		switch {
		case cell.x == N / 2 && cell.y == N / 2 && v == 0: explain = "The center: where the tiles are drawn (it can hold a value too)."
		case v == 0: explain = "This cell's content doesn't matter."
		case v > 0: explain = fmt.tprintf("This cell should contain %s to match.", rValueName(values, groups, v))
		case: explain = fmt.tprintf("This cell should NOT contain %s to match.", rValueName(values, groups, v))
		}
	}
	// A press starts LDtk's drawing (RulePatternEditor's draw)
	pressed := -1
	if hovered && !drag.active {
		if ctx.input.mouse_pressed[.Left] do pressed = 0
		else if ctx.input.mouse_pressed[.Middle] do pressed = 1
		else if ctx.input.mouse_pressed[.Right] do pressed = 2
	}
	if pressed >= 0 {
		drag^ = {active = true, rule = r.uid, button = pressed, start = grid[cell.x + cell.y * N], grid = grid}
		ctx.input.mouse_pressed[.Right] = false
	}
	if drag.active && drag.rule == r.uid {
		if inside {
			i := cell.x + cell.y * N
			v := drag.grid[i]
			selected := s.level.rules.value
			switch drag.button {
			case 0:
				// Require the value (or clear a forbidden one)
				if drag.start >= 0 do drag.grid[i] = selected
				else if v < 0 do drag.grid[i] = 0
			case 2:
				// Forbid it (or clear)
				if drag.start == 0 do drag.grid[i] = -selected
				else do drag.grid[i] = 0
			case 1:
				drag.grid[i] = 0
			}
			if drag.grid[i] != v do drag.changed = true
		}
		if !ctx.input.mouse_buttons[.Left] && !ctx.input.mouse_buttons[.Right] && !ctx.input.mouse_buttons[.Middle] {
			if drag.changed {
				e := rEdit(c, .Rule_Pattern, layerUid, rule = r.uid)
				e.number = N
				e.ids = slice.clone(drag.grid[:], context.temp_allocator)
				skald.send(ctx, Msg(e))
			}
			drag^ = {}
		} else {
			skald.send(ctx, Msg(Frame_Requested{}))
		}
		grid = drag.grid
	}
	Paint :: struct {
		grid: [81]int,
		cell: f32,
		values: []RulesValue,
		groups: []RulesGroup,
		empty, line, accent: skald.Color,
		stamp: bool,
		stampSize: [2]int,
		pivot: [2]f32,
		hover: [2]int,
		hovered: bool,
	}
	p := new(Paint, context.temp_allocator)
	p^ = {grid = grid, cell = cellPx, values = values, groups = groups, empty = th.color.surface, line = th.color.border, accent = th.color.primary,
		stamp = r.tileMode == .Stamp, pivot = {f32(r.pivot.x), f32(r.pivot.y)}, hover = cell, hovered = hovered}
	if p.stamp && len(r.tileRectsIds) > 0 && len(r.tileRectsIds[0]) > 1 {
		x0, y0, x1, y1 := 1 << 30, 1 << 30, -1, -1
		for id in r.tileRectsIds[0] {
			cx, cy := id % max(ts.cWid, 1), id / max(ts.cWid, 1)
			x0, y0, x1, y1 = min(x0, cx), min(y0, cy), max(x1, cx), max(y1, cy)
		}
		p.stampSize = {x1 - x0 + 1, y1 - y0 + 1}
	}
	canvas := skald.canvas(ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		rr, b := painter.r, painter.bounds
		skald.draw_rect(rr, b, p.line)
		for cy in 0 ..< N do for cx in 0 ..< N {
			rect := skald.Rect{b.x + f32(cx) * p.cell + 1, b.y + f32(cy) * p.cell + 1, p.cell - 2, p.cell - 2}
			rDrawCell(rr, rect, p.grid[cx + cy * N], p.values, p.groups, p.empty)
		}
		// The center: where the tiles go (a stamp's extent from its pivot)
		c := skald.Rect{b.x + f32(N / 2) * p.cell, b.y + f32(N / 2) * p.cell, p.cell, p.cell}
		if p.stamp && (p.stampSize.x > 1 || p.stampSize.y > 1) {
			w, h := f32(p.stampSize.x) * p.cell, f32(p.stampSize.y) * p.cell
			sr := skald.Rect{c.x + p.pivot.x * (p.cell - w), c.y + p.pivot.y * (p.cell - h), w, h}
			skald.draw_rect_outline(rr, sr, 2, {1, 0.8, 0.2, 0.9})
		}
		skald.draw_rect_outline(rr, c, 2, p.accent)
		if p.hovered {
			h := skald.Rect{b.x + f32(p.hover.x) * p.cell, b.y + f32(p.hover.y) * p.cell, p.cell, p.cell}
			skald.draw_rect_outline(rr, h, 1, {1, 1, 1, 0.9})
		}
	}, id = id, width = cellPx * N, height = cellPx * N, cursor = .Crosshair)
	append(c.rows, skald.row(skald.spacer(c.stacked ? 0 : LDTK_LABEL_WIDTH), canvas))
	return explain
}

// RuleModuloEditor's preview: the cells a modulo and offset let the rule apply in
@(private="file")
rModuloPreview :: proc(c: ^LDtkTabCtx, r: ^LDtkRule) -> skald.View {
	th := c.ctx.theme
	Paint :: struct {
		xm, ym, xo, yo, cols, rows: int,
		on, off: skald.Color,
	}
	p := new(Paint, context.temp_allocator)
	p^ = {xm = max(r.xModulo, 1), ym = max(r.yModulo, 1), xo = r.xOffset, yo = r.yOffset, on = th.color.primary, off = th.color.surface}
	p.cols, p.rows = max(p.xm + 3, 8), max(p.ym + 3, 8)
	cell := min(f32(12), (min(c.rowWidth, 300)) / f32(p.cols))
	view := skald.canvas(c.ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		rr, b := painter.r, painter.bounds
		cw, ch := b.w / f32(p.cols), b.h / f32(p.rows)
		for cy in 0 ..< p.rows do for cx in 0 ..< p.cols {
			active := (cx - p.xo) % p.xm == 0 && (cy - p.yo) % p.ym == 0
			skald.draw_rect(rr, {b.x + f32(cx) * cw + 1, b.y + f32(cy) * ch + 1, cw - 2, ch - 2}, active ? p.on : p.off)
		}
	}, width = cell * f32(p.cols), height = cell * f32(p.rows))
	return skald.row(skald.spacer(c.stacked ? 0 : LDTK_LABEL_WIDTH), view)
}

// --- The Assistant ------------------------------------------------------------------------------

/*
LDtk's Rule Assistant (RulesWizard): the main and outer values, the group's name, the wall parts'
grid (a part picked, then its tiles on the tileset: a drag replaces, Shift adds, the right button
removes; a right click on a part clears it), the stacking option, then Create (or Update) rules.
*/
@(private="file")
rulesAssistant :: proc(c: ^LDtkTabCtx, layerUid, layer: int) {
	tk := uiTokens(c.ctx)
	ctx := c.ctx
	s := c.s
	th := ctx.theme
	r := &s.level.rules
	a := &r.assistant
	editing := r.group >= 0
	LevelRules_SetHovered(-1, -1, -1)
	tabHeading(c, editing ? "Rule Assistant: edit the group's rules" : "Rule Assistant: a new group of rules")
	values, groups := rSourceValues(c, layer)
	labels := make([dynamic]string, context.temp_allocator)
	vals := make([dynamic]string, context.temp_allocator)
	for v in values {
		append(&labels, v.name != "" ? fmt.tprintf("%d - %s", v.value, v.name) : fmt.tprint(v.value))
		append(&vals, fmt.tprint(v.value))
	}
	main := skald.select(ctx, a.main > 0 ? rValueLabel(values, a.main) : "< pick a value >", labels[:], 0, proc(_: int, v: string) -> Msg {
		n, _ := tabParseInt(strings.split(v, " ", context.temp_allocator)[0])
		return Rules_View{op = .Assistant_Main, number = n}
	}, id = skald.hash_id("ldtk-assistant-main"), width = c.controlWidth)
	tabRow(c, "Main value", main, "The IntGrid value its rules draw tiles for")
	otherLabels := make([dynamic]string, context.temp_allocator)
	append(&otherLabels, "< any other IntGrid value >")
	for v in values do if v.value != a.main do append(&otherLabels, v.name != "" ? fmt.tprintf("%d - %s", v.value, v.name) : fmt.tprint(v.value))
	other := skald.select(ctx, a.other > 0 ? rValueLabel(values, a.other) : otherLabels[0], otherLabels[:], 0, proc(_: int, v: string) -> Msg {
		n, _ := tabParseInt(strings.split(v, " ", context.temp_allocator)[0])
		return Rules_View{op = .Assistant_Other, number = n}
	}, id = skald.hash_id("ldtk-assistant-other"), width = c.controlWidth)
	tabRow(c, "Outer value", other, "Without one, the rules check the main value is next to anything that isn't it; with one, next to that value (for example grass next to dirt)")
	nameId := skald.hash_id("ldtk-assistant-name")
	nameText := r.name
	if s.numberEdit.id == nameId && skald.widget_has_focus(ctx, nameId) do nameText = s.numberEdit.text
	name := skald.text_input(ctx, strings.clone(nameText, context.temp_allocator), 0, proc(_: int, v: string) -> Msg {
		return Rules_View{op = .Assistant_Name, text = v}
	}, id = nameId, width = c.controlWidth, padding = tk.fieldPadding)
	tabRow(c, "Group's name", name, "The new group's name")
	// The parts' grid (each a cell of LDtk's 12 x 5 layout)
	tsUid := rLayerTileset(c, layerUid, layer)
	ts := rTileset(c, tsUid)
	tabNote(c, fmt.tprintf("Part: %v. Pick its tiles on the tileset below (several: one at random); a right click on a part clears it. You don't have to fill them all: mirrored parts are used for the missing ones (faded).", r.part))
	gridKey := "ldtk-assistant-grid"
	gridId := skald.hash_id(gridKey)
	cols, rows := LDTK_ASSISTANT_GRID.x, LDTK_ASSISTANT_GRID.y
	cell := clamp(c.rowWidth / f32(cols), 20, 48)
	if rHovered(ctx, gridId) {
		rr := lastRect(ctx, gridId)
		local := ctx.input.mouse_pos - {rr.x, rr.y}
		at := [2]int{int(local.x / cell), int(local.y / cell)}
		for f in LDtkWallFragment do if LDTK_WALL_FRAGMENT_AT[f] == at {
			skald.cursor_request(ctx, .Pointer)
			if ctx.input.mouse_pressed[.Left] do skald.send(ctx, Msg(Rules_View{op = .Assistant_Part, number = int(f)}))
			if ctx.input.mouse_pressed[.Right] || ctx.input.mouse_pressed[.Middle] {
				skald.send(ctx, Msg(Rules_View{op = .Assistant_Part, number = int(f)}))
				skald.send(ctx, Msg(Rules_View{op = .Assistant_Tiles, number = int(f)}))
				ctx.input.mouse_pressed[.Right] = false
			}
		}
	}
	Part :: struct {
		at: [2]int,
		cells: [3]string,
		tile: int,
		flipX, flipY, mirrored, current: bool,
	}
	Paint :: struct {
		parts: [len(LDtkWallFragment)]Part,
		cell: f32,
		ts: RulesTileset,
		main, other, accent, empty: skald.Color,
	}
	p := new(Paint, context.temp_allocator)
	p.cell, p.ts, p.accent, p.empty = cell, ts, th.color.primary, th.color.surface
	mc, _ := rCellColor(values, groups, max(a.main, 1))
	// The outer value's color; without one, "not the main value" (dark red)
	oc := skald.Color{0.35, 0.08, 0.08, 1}
	if a.other > 0 do oc, _ = rCellColor(values, groups, a.other)
	p.main, p.other = mc, oc
	for f in LDtkWallFragment {
		part := Part{at = LDTK_WALL_FRAGMENT_AT[f], cells = LDtkWallFragment_Matrix(f), tile = -1, current = f == r.part}
		if len(a.tiles[f]) > 0 {
			part.tile = a.tiles[f][0]
		} else if alt, fx, fy, has := LDtkAssistant_Alternative(a, f); has {
			part.tile, part.flipX, part.flipY, part.mirrored = a.tiles[alt][0], fx, fy, true
		}
		p.parts[int(f)] = part
	}
	canvas := skald.canvas(ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		rr, b := painter.r, painter.bounds
		for part in p.parts {
			cell := skald.Rect{b.x + f32(part.at.x) * p.cell + 1, b.y + f32(part.at.y) * p.cell + 1, p.cell - 2, p.cell - 2}
			skald.draw_rect(rr, cell, p.empty)
			if part.tile >= 0 && p.ts.ok {
				src := rTileSrc(p.ts, part.tile)
				if part.flipX do src.x, src.w = src.x + src.w, -src.w
				if part.flipY do src.y, src.h = src.y + src.h, -src.h
				skald.draw_image_region(rr, p.ts.path, cell, src, tint = {1, 1, 1, part.mirrored ? 0.4 : 1}, inset = false)
			}
			// The part's pattern (the Assistant's icons): the whole cell without tiles, a corner with
			m := part.tile >= 0 ? p.cell * 0.36 : cell.w
			ox := part.tile >= 0 ? cell.x + cell.w - m - 1 : cell.x
			oy := part.tile >= 0 ? cell.y + 1 : cell.y
			for line, y in part.cells do for ch, x in line {
				col := ch == 'o' ? p.main : ch == 'x' ? p.other : skald.Color{0, 0, 0, 0}
				if col.a == 0 do continue
				q := skald.Rect{ox + f32(x) * m / 3, oy + f32(y) * m / 3, m / 3, m / 3}
				skald.draw_rect(rr, q, {col.r, col.g, col.b, part.tile >= 0 ? 0.8 : 1})
				if part.tile < 0 do skald.draw_rect_outline(rr, q, 1, {0, 0, 0, 0.5})
			}
			if part.current do skald.draw_rect_outline(rr, cell, 2, p.accent)
		}
	}, id = gridId, width = cell * f32(cols), height = cell * f32(rows))
	append(c.rows, canvas)
	picker, picked := rTilePicker(c, "assistant-tiles", ts, a.tiles[r.part][:], maxHeight = 240)
	append(c.rows, picker)
	if picked.picked do skald.send(ctx, Msg(Rules_View{op = .Assistant_Tiles, number = int(r.part), ids = rIndividuals(a.tiles[r.part][:], picked)}))
	stack := skald.checkbox(ctx, !a.breakOnMatch, "Allow rules to stack", 0, proc(_: int, v: bool) -> Msg { return Msg(Rules_View{op = .Assistant_Stack, flag = v}) }, id = skald.hash_id("ldtk-assistant-stack"))
	tabRow(c, "Options", skald.tooltip(ctx, stack, "Several rules may apply to one cell: their tiles stack (useful when the tiles are transparent); otherwise only the topmost applies", id = skald.hash_id("ldtk-assistant-stack-tip")), "The rules' break on match")
	edit := rEdit(c, .Rule_Group_Assistant, layerUid, group = r.group)
	edit.text = strings.clone(r.name, context.temp_allocator)
	edit.ids = LDtkAssistant_Encode(a)
	rButtons(c, rButton(c, "ldtk-assistant-create", editing ? "Update rules" : "Create rules", Msg(edit), disabled = a.main <= 0),
		rButton(c, "ldtk-assistant-clear", "Clear the part", Msg(Rules_View{op = .Assistant_Tiles, number = int(r.part)}), disabled = len(a.tiles[r.part]) == 0),
		rButton(c, "ldtk-assistant-cancel", "Cancel", Msg(Rules_View{op = .Close})))
}

// A group's name by its uid
@(private="file")
rGroupName :: proc(groups: []RulesGroup, uid: int) -> string {
	for g in groups do if g.uid == uid do return fmt.tprintf("Group %s", g.name)
	return fmt.tprintf("Group %d", uid)
}

// A value's label in the Assistant's choices
@(private="file")
rValueLabel :: proc(values: []RulesValue, value: int) -> string {
	for v in values do if v.value == value do return v.name != "" ? fmt.tprintf("%d - %s", v.value, v.name) : fmt.tprint(v.value)
	return fmt.tprint(value)
}

// --- Duplicate and Remap, the icon, the color ---------------------------------------------------

/*
LDtk's Duplicate and Remap (RuleGroupRemap): each IntGrid value its rules use given another, the
tiles moved on the tileset (a click on the tile the group's first tile becomes: the originals
dark green, where they go green, or red past the edge), the copy's name, Confirm.
*/
@(private="file")
rulesRemap :: proc(c: ^LDtkTabCtx, layerUid, layer: int) {
	tk := uiTokens(c.ctx)
	ctx := c.ctx
	s := c.s
	r := &s.level.rules
	LevelRules_SetHovered(-1, -1, -1)
	groups := LDtkRules_ReadGroups(c.main, layer)
	gi := -1
	for g, i in groups do if g.uid == r.group do gi = i
	if gi < 0 {
		skald.send(ctx, Msg(Rules_View{op = .Close}))
		return
	}
	g := &groups[gi]
	tabHeading(c, fmt.tprintf("Duplicate group \"%s\"", g.name))
	values, intGroups := rSourceValues(c, layer)
	tabNote(c, "Remap the IntGrid values its rules use:")
	olds := make([dynamic]int, context.temp_allocator)
	for old in r.remap do append(&olds, old)
	slice.sort(olds[:])
	labels := make([dynamic]string, context.temp_allocator)
	vals := make([dynamic]string, context.temp_allocator)
	for v in values {
		append(&labels, v.name != "" ? fmt.tprintf("%d - %s", v.value, v.name) : fmt.tprint(v.value))
		append(&vals, fmt.tprint(v.value))
	}
	// A group's rule value takes another group's (or "ungrouped")
	groupLabels := make([dynamic]string, context.temp_allocator)
	groupVals := make([dynamic]string, context.temp_allocator)
	append(&groupLabels, "Ungrouped values")
	append(&groupVals, "1000")
	for x in intGroups {
		append(&groupLabels, fmt.tprintf("Group %s", x.name))
		append(&groupVals, fmt.tprint((x.uid + 1) * 1000))
	}
	for old in olds {
		Pick :: struct { old: int }
		ls, vs := labels[:], vals[:]
		if old > 999 do ls, vs = groupLabels[:], groupVals[:]
		choice := labeledSelect(ctx, fmt.tprint(r.remap[old]), ls, vs, Pick{old}, proc(p: Pick, v: string) -> Msg {
			n, _ := tabParseInt(v)
			return Rules_View{op = .Remap_Value, number = p.old, uid = n}
		}, id = skald.hash_id(fmt.tprintf("ldtk-remap-%d", old)), width = c.controlWidth)
		name := old > 999 ? (old == 1000 ? "Ungrouped" : rGroupName(intGroups, old / 1000 - 1)) : rValueLabel(values, old)
		tabRow(c, fmt.tprintf("%s →", name), choice, "The value it becomes in the copy (\"not\" values too)")
	}
	ts := rTileset(c, nodeUid(c.main, Json_Get(c.main, layer, "tilesetDefUid")))
	all := make([dynamic]int, context.temp_allocator)
	for x in g.rules do for ids in x.tileRectsIds do for id in ids do if !slice.contains(all[:], id) do append(&all, id)
	slice.sort(all[:])
	moved := make([dynamic]int, context.temp_allocator)
	valid := true
	for id in all {
		cx, cy := id % max(ts.cWid, 1) + r.offset.x, id / max(ts.cWid, 1) + r.offset.y
		if cx < 0 || cy < 0 || cx >= ts.cWid || cy >= ts.cHei do valid = false
		else do append(&moved, cx + cy * ts.cWid)
	}
	tabNote(c, fmt.tprintf("Transpose the tiles: click where the first tile goes (moved by %d, %d)%s.", r.offset.x, r.offset.y, valid ? "" : ": some go past the tileset's edge"), !valid)
	original: []int = nil
	if r.offset != {} do original = all[:]
	picker, picked := rTilePicker(c, "remap-tiles", ts, nil, marked = original, markColor = 0x008800, marked2 = moved[:], markColor2 = valid ? 0x00FF00 : 0xFF0000, maxHeight = 240)
	append(c.rows, picker)
	if picked.picked && len(all) > 0 {
		first := all[0]
		target := picked.box[0] + picked.box[1] * ts.cWid
		offset := make([]int, 2, context.temp_allocator)
		offset[0], offset[1] = target % ts.cWid - first % ts.cWid, target / ts.cWid - first / ts.cWid
		skald.send(ctx, Msg(Rules_View{op = .Remap_Offset, ids = offset}))
	}
	nameId := skald.hash_id("ldtk-remap-name")
	nameText := r.name
	if s.numberEdit.id == nameId && skald.widget_has_focus(ctx, nameId) do nameText = s.numberEdit.text
	name := skald.text_input(ctx, strings.clone(nameText, context.temp_allocator), 0, proc(_: int, v: string) -> Msg {
		return Rules_View{op = .Remap_Name, text = v}
	}, id = nameId, width = c.controlWidth, padding = tk.fieldPadding)
	tabRow(c, "New name", name, "The copy's name")
	edit := rEdit(c, .Rule_Group_Remapped, layerUid, group = g.uid)
	edit.text = strings.clone(r.name, context.temp_allocator)
	pairs := make([dynamic]int, context.temp_allocator)
	for old in olds do append(&pairs, old, r.remap[old])
	edit.ids = pairs[:]
	edit.number, edit.number2 = f64(r.offset.x), f64(r.offset.y)
	rButtons(c, rButton(c, "ldtk-remap-confirm", "Confirm", Msg(edit), disabled = !valid || strings.trim_space(r.name) == ""),
		rButton(c, "ldtk-remap-cancel", "Cancel", Msg(Rules_View{op = .Close})))
}

// A group's icon picked on the layer's tileset (LDtk's onPickGroupIcon)
@(private="file")
rulesIcon :: proc(c: ^LDtkTabCtx, layerUid, layer: int) {
	ctx := c.ctx
	r := &c.s.level.rules
	LevelRules_SetHovered(-1, -1, -1)
	tabHeading(c, "The group's icon: drag a tile (or a rectangle) on the tileset")
	ts := rTileset(c, rLayerTileset(c, layerUid, layer))
	picker, picked := rTilePicker(c, "icon-tiles", ts, nil)
	append(c.rows, picker)
	if picked.picked {
		b := picked.box
		x := int(ts.padding) + b[0] * int(ts.grid + ts.spacing)
		y := int(ts.padding) + b[1] * int(ts.grid + ts.spacing)
		right := int(ts.padding) + b[2] * int(ts.grid + ts.spacing) + int(ts.grid)
		bottom := int(ts.padding) + b[3] * int(ts.grid + ts.spacing) + int(ts.grid)
		e := rEdit(c, .Rule_Group_Set, layerUid, group = r.group)
		e.key, e.text, e.number = "icon", fmt.tprintf("%d,%d,%d,%d", x, y, right - x, bottom - y), f64(ts.uid)
		skald.send(ctx, Msg(e))
	}
	rButtons(c, rButton(c, "ldtk-icon-cancel", "Cancel", Msg(Rules_View{op = .Close})))
}

// A group's color picked from LDtk's palette (or typed)
@(private="file")
rulesColor :: proc(c: ^LDtkTabCtx, layerUid, layer: int) {
	tk := uiTokens(c.ctx)
	ctx := c.ctx
	th := ctx.theme
	r := &c.s.level.rules
	LevelRules_SetHovered(-1, -1, -1)
	groups := LDtkRules_ReadGroups(c.main, layer)
	current := -1
	for g in groups do if g.uid == r.group do current = g.color
	tabHeading(c, "The group's color")
	swatches := make([dynamic]skald.View, context.temp_allocator)
	for col, i in LDTK_NICE_PALETTE {
		e := rEdit(c, .Rule_Group_Set, layerUid, group = r.group)
		e.key, e.text = "color", LDtk_FormatColor(col)
		b := skald.button(ctx, "", Msg(e), id = skald.hash_id(fmt.tprintf("ldtk-color-%d", i)), bg = skald.rgb(u32(col)), width = tk.panelButtonWidth, padding = {0, tk.xs}, radius = th.radius.sm)
		append(&swatches, col == current ? skald.col(b, padding = tk.xxs, bg = th.color.fg, radius = th.radius.sm) : skald.col(b, padding = tk.xxs))
	}
	rButtons(c, ..swatches[:])
	e := rEdit(c, .Rule_Group_Set, layerUid, group = r.group)
	e.key = "color"
	tabRow(c, "Color", tabColorField(c, "ldtk-color-hex", current >= 0 ? LDtk_FormatColor(current) : "", e), "#RRGGBB")
	// LDtk's color wheel (its ColorPicker): Skald's picker
	wheel := skald.color_picker(ctx, current >= 0 ? skald.rgb(u32(current)) : skald.rgb(0xFFFFFF), e, proc(edit: LDtk_Edit, v: skald.Color) -> Msg {
		x := edit
		x.text = strings.concatenate({"#", skald.color_to_hex(v)}, context.temp_allocator)
		return x
	}, id = skald.hash_id("ldtk-color-wheel"), width = min(c.controlWidth, tk.fieldM))
	tabRow(c, "Any color", wheel, "pick any color on a wheel")
	none := e
	none.text = ""
	rButtons(c, rButton(c, "ldtk-color-none", "No color", Msg(none), disabled = current < 0), rButton(c, "ldtk-color-cancel", "Done", Msg(Rules_View{op = .Close})))
}

// --- Menus ---------------------------------------------------------------------------------------

// The + Group button's menu
Ctx_Rules_New :: struct {
	layer: int,
}

// A group's menu (its ⋯ or a right click on its header)
Ctx_Rule_Group :: struct {
	layer, group: int,
}

// A rule's menu (a right click on its row)
Ctx_Rule :: struct {
	layer, group, rule: int,
}

// The tab's menus (LDtk's context menus of a group and a rule)
LevelRules_MenuItems :: proc(s: ^State, items: ^[dynamic]skald.Menu_Item(Msg), target: ContextTarget) {
	file := LevelMode_File(s)
	doc := LDtkDoc_Get(s.project.rootPath, file)
	if doc == nil || doc.problem != "" do return
	main := LDtkDoc_Main(doc)
	f := strings.clone(file, context.temp_allocator)
	level := ""
	if l := LDtkDoc_FindLevel(doc, s.level.level); l >= 0 do _, level = LDtkDoc_LevelNames(doc, l)
	level = strings.clone(level, context.temp_allocator)
	edit :: proc(f: string, op: LDtkEditOp, layer: int, group := -1, rule := -1) -> LDtk_Edit {
		return {op = op, file = f, def = layer, index = group, field = rule}
	}
	item :: proc(label: string, msg: Msg, disabled := false, checked := false) -> skald.Menu_Item(Msg) {
		return {label = label, msg = msg, disabled = disabled, checked = checked}
	}
	clip := s.level.rules.clipKind
	clipText := strings.clone(s.level.rules.clip, context.temp_allocator)
	#partial switch t in target {
	case Ctx_Rules_New:
		append(items,
			item("Use the Assistant (recommended)", Msg(Rules_View{op = .Assistant, uid = -1})),
			item("Create an empty group", Msg(edit(f, .Rule_Group_Added, t.layer))))
		if clip == .Group {
			paste := edit(f, .Rule_Pasted, t.layer)
			paste.key, paste.text = "group", clipText
			append(items, item("Paste group", Msg(paste)))
		}
	case Ctx_Rule_Group:
		layer := LDtkDoc_DefByUid(doc, "layers", t.layer)
		if layer < 0 do return
		groups := LDtkRules_ReadGroups(main, layer)
		gi := groupIndex(groups[:], t.group)
		if gi < 0 do return
		g := &groups[gi]
		cut := edit(f, .Rule_Group_Removed, t.layer, t.group)
		cut.key = "cut"
		paste := edit(f, .Rule_Pasted, t.layer, t.group)
		paste.key, paste.text = "group", clipText
		append(items,
			item("Copy group", Msg(Rules_View{op = .Copy, uid = t.group, number = -1})),
			item("Cut group", Msg(cut)),
			item("Paste group after", Msg(paste), disabled = clip != .Group),
			item("Duplicate group", Msg(edit(f, .Rule_Group_Duplicated, t.layer, t.group))),
			item("Delete group", Msg(edit(f, .Rule_Group_Removed, t.layer, t.group))),
			MENU_SEPARATOR,
			item("Rename", Msg(Rules_View{op = .Rename, uid = t.group})),
			item("Duplicate and remap...", Msg(Rules_View{op = .Remap, uid = t.group})),
			MENU_SEPARATOR,
			item("Assign group color...", Msg(Rules_View{op = .Color, uid = t.group})),
			item("Assign group icon...", Msg(Rules_View{op = .Icon, uid = t.group})))
		if g.hasIcon {
			noIcon := edit(f, .Rule_Group_Set, t.layer, t.group)
			noIcon.key = "icon"
			append(items, item("Remove group icon", Msg(noIcon)))
		}
		// Every rule's out-of-bounds policy (LDtk's dialog: the same choices)
		oob := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
		values, _, _ := LDtkRules_SourceValues(doc, layer)
		ordered := LevelRules_Values(doc, layer)
		set := edit(f, .Rule_Group_Set, t.layer, t.group)
		set.key = "outOfBoundsValue"
		append(&oob, item("Don't apply past the layer's edges (default)", Msg(set)))
		empty := set
		empty.text = "0"
		append(&oob, item("Empty cells", Msg(empty)))
		for v in ordered {
			x := set
			x.text = fmt.tprint(v)
			append(&oob, item(fmt.tprintf("Value %d", v), Msg(x)))
		}
		_ = values
		append(items, MENU_SEPARATOR, skald.Menu_Item(Msg){label = "Edit \"out-of-bounds\" policy for all rules", submenu = oob[:]})
		if g.usesWizard do append(items, item("Edit rules using the Assistant", Msg(Rules_View{op = .Assistant, uid = t.group})))
		// Biomes (LDtk's picker: any, each value checked, AND / OR)
		if known, ok := LDtkRules_BiomeValues(doc, layer); ok {
			biome := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
			any := edit(f, .Rule_Group_Set, t.layer, t.group)
			any.key = "requiredBiomeValues"
			append(&biome, item("Any biome", Msg(any), checked = len(g.biome) == 0))
			for v in known {
				next := make([dynamic]string, context.temp_allocator)
				on := slice.contains(g.biome[:], v)
				for b in g.biome do if b != v do append(&next, b)
				if !on do append(&next, v)
				x := any
				x.text = strings.join(next[:], ",", context.temp_allocator)
				append(&biome, item(v, Msg(x), checked = on))
			}
			if len(g.biome) > 1 {
				or, and := edit(f, .Rule_Group_Set, t.layer, t.group), edit(f, .Rule_Group_Set, t.layer, t.group)
				or.key, and.key = "biomeRequirementMode", "biomeRequirementMode"
				and.number = 1
				append(&biome, MENU_SEPARATOR, item("OR: at least one of the checked values", Msg(or), checked = g.biomeMode == 0), item("AND: all the checked values", Msg(and), checked = g.biomeMode == 1))
			}
			append(items, skald.Menu_Item(Msg){label = "Assign biome enum", submenu = biome[:]})
		} else {
			append(items, item("Assign biome enum (the layer has no biome field: the Layers tab)", Msg(Bottom_Tab_Picked(BottomTab.Layers))))
		}
		optional := edit(f, .Rule_Group_Set, t.layer, t.group)
		optional.key, optional.flag = "isOptional", !g.isOptional
		// LDtk 1.5.3 offers these the wrong way round (EditAllAutoLayerRules); here as its labels mean
		append(items, item(g.isOptional ? "Disable OPTIONAL state (the levels lose their on / off state)" : "Turn into an OPTIONAL group (off everywhere, turned on per level)", Msg(optional)))
		_ = level
	case Ctx_Rule:
		cut := edit(f, .Rule_Removed, t.layer, t.group, t.rule)
		cut.key = "cut"
		paste := edit(f, .Rule_Pasted, t.layer, t.group, t.rule)
		paste.key, paste.text = "rule", clipText
		append(items,
			item("Edit rule...", Msg(Rules_View{op = .Edit, uid = t.rule})),
			MENU_SEPARATOR,
			item("Copy rule", Msg(Rules_View{op = .Copy, uid = t.group, number = t.rule})),
			item("Cut rule", Msg(cut)),
			item("Paste rule after", Msg(paste), disabled = clip != .Rule),
			item("Duplicate rule", Msg(edit(f, .Rule_Duplicated, t.layer, t.group, t.rule))),
			item("Delete rule", Msg(edit(f, .Rule_Removed, t.layer, t.group, t.rule))))
	}
}
