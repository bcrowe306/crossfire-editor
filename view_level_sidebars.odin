package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

/*
The Level mode's sidebars (level_mode.odin), the editor's panels as the Scene mode has them: a
panel header (`panelHeader`, the browser's and the scene tree's), its choices under it as the
browser's search row, then a list whose rows are the scene tree's (`rowList`: `Tree_RowView`,
`settings.rowHeight`, the same font, icons, indent and selection colors). Their widths, minimums
and fitting are the Scene mode's sidebars' (`FittedSidebarWidths`).

- **Levels** (left, where the project browser is): the header (+: New Level, a spot picked on the
  canvas), the LDtk file's choice (with several in the project) and the world's (with several
  worlds: LDtk's Multi-worlds), then a row per level of the world. A click selects the level (and
  the canvas shows it selected), a double-click focuses it (the canvas fits it, as LDtk's level
  view), a right-click opens its menu (`Ctx_Level`); Up / Down pick the next one. Without an LDtk
  file: Import...
- **Layers** (right, where the scene tree is): the selected level's layers, top first (LDtk's
  order), then the palette of the selected layer (view_level_palette.odin: its IntGrid values, its
  tileset, its entity types). A row: the layer type's icon (in its list color), its name, the eye
  (LDtk's: the layer instance's `visible`, saved in the file; the engine skips hidden layers). A
  click selects the layer (the tools and the Layers tab follow it); a row dragged as the scene
  tree's rows are moves the layer (`Layer_Move`: the definitions' order, every level's with it).
  Without a selected level: the project's layer definitions (no eyes).

Keys: `level-row-<i>` (i: the level's place in the world), `level-list` (the list),
`level-list-scroll`, `level-new`, `level-file`, `level-world`, `level-import`,
`level-layer-row-<i>`, `level-layer-eye-<i>` (i: the layer's place, top first), `level-layers`,
`level-layers-scroll`.
*/

// A layer row being dragged: the layer (its definition's uid), where it was, where it goes, where
// the press was (file state: only the view follows it, the release sends the edit)
@(private="file")
LayerRowDrag :: struct {
	pressed, active: bool,
	def, from, to: int,
	start: [2]f32,
}
@(private="file")
layerRowDrag: LayerRowDrag

// The Levels sidebar (the left one)
levelLevelsSidebarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(..levelLevelsPart(s, ctx), cross_align = .Stretch, bg = th.color.bg)
}

// The Layers sidebar (the right one)
levelLayersSidebarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(..levelLayersPart(s, ctx), cross_align = .Stretch, bg = th.color.bg)
}

// The width rows' text gets in a sidebar (its fitted width, less the row's indent and icon)
@(private="file")
sidebarTextWidth :: proc(s: ^State, ctx: ^skald.Ctx(Msg), right: bool) -> f32 {
	left, rightWidth := FittedSidebarWidths(Mode_LayoutOf(s, .Level))
	return max((right ? rightWidth : left) - 90, 60)
}

/*
The Levels sidebar's content: the header, the file and world choices, the level rows (or, without
an LDtk file, how to bring one in).
*/
@(private="file")
levelLevelsPart :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	th := ctx.theme
	parts := make([dynamic]skald.View, context.temp_allocator)
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	readable := doc != nil && doc.problem == ""
	levels := readable ? LevelMode_WorldLevels(s, doc) : nil
	// LDtk's world panel's New level: a spot picked on the canvas (level_world_tools.odin)
	actions := make([dynamic]skald.View, context.temp_allocator)
	if readable {
		append(&actions, panelToolButton(ctx, "level-new", s.level.spot ? ICON_CROSSHAIRS : ICON_PLUS,
			s.level.spot ? "Picking a spot for the new level on the canvas (Esc cancels)" : "New Level: pick its spot on the canvas",
			Msg(Level_Spot_Started{cancel = s.level.spot}), on = s.level.spot))
	}
	title := readable ? fmt.tprintf("Levels (%d)", len(levels)) : "Levels"
	append(&parts, panelHeader(ctx, ICON_MAP, title, ..actions[:]))
	textWidth := sidebarTextWidth(s, ctx, false)
	if file == "" {
		append(&parts, skald.divider(ctx), skald.col(
			skald.text("No LDtk project yet: import an .ldtk file (LDtk, ldtk.io) and its levels show here.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60),
			skald.button(ctx, fmt.tprintf("%s  Import...", ICON_PLUS), Msg(Action.Import_Asset), id = skald.hash_id("level-import"),
				bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_sm),
			spacing = th.spacing.sm,
			padding = th.spacing.sm,
		))
		return parts[:]
	}
	// The LDtk file (several in the project) and the world (several in the file), where the
	// browser has its search box
	choices := make([dynamic]skald.View, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	for asset in s.project.assets do if asset.kind == .LDtk do append(&files, asset.path)
	if len(files) > 1 {
		append(&choices, skald.flex(1, labeledSelect(ctx, file, Asset_DisplayNames(files[:]), files[:], 0, proc(_: int, path: string) -> Msg {
			return Level_File_Chosen(path)
		}, id = skald.hash_id("level-file"))))
	}
	if readable && len(doc.worlds) > 1 {
		names := make([dynamic]string, context.temp_allocator)
		iids := make([dynamic]string, context.temp_allocator)
		for _, w in doc.worlds {
			name, iid := LDtkDoc_WorldNames(doc, w)
			append(&names, fmt.tprintf("%s  %s", ICON_GLOBE, name))
			append(&iids, iid)
		}
		_, shown := LDtkDoc_WorldNames(doc, LevelMode_World(s, doc))
		append(&choices, skald.flex(1, labeledSelect(ctx, shown, names[:], iids[:], 0, proc(_: int, iid: string) -> Msg {
			return Level_World_Chosen(iid)
		}, id = skald.hash_id("level-world"))))
	}
	if len(choices) > 0 do append(&parts, skald.col(..choices[:], spacing = th.spacing.xs, padding = th.spacing.xs, cross_align = .Stretch))
	append(&parts, skald.divider(ctx))
	switch {
	case doc == nil:
		append(&parts, placeholder(ctx, fmt.tprintf("%s can't be read.", filepath.base(file))))
		return parts[:]
	case doc.problem != "":
		append(&parts, placeholder(ctx, "It can't be read as an LDtk project (the canvas says why)."))
		return parts[:]
	}
	color := AssetKind_Color(.LDtk)
	rows := make([dynamic]ListRow, context.temp_allocator)
	tree := make([dynamic]ColoredTreeRow, context.temp_allocator)
	for index, i in levels {
		identifier, _ := LDtkDoc_LevelNames(doc, index)
		name := strings.clone(identifier, context.temp_allocator)
		row := ColoredTreeRow{label = name, icon = ICON_FILE_LINES, iconColor = color, labelColor = TintLabel(th, color), selected = identifier == s.level.level}
		// The focused level (the canvas's level view)
		if identifier == s.level.focus do row.badge = ICON_CROSSHAIRS
		append(&rows, ListRow{row = row, key = fmt.tprintf("level-row-%d", i), pick = Msg(Level_Row_Clicked{level = name})})
		append(&tree, row)
	}
	if len(rows) == 0 {
		append(&parts, skald.col(skald.text("This world has no levels: + (New Level) adds one.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60), padding = th.spacing.sm))
		return parts[:]
	}
	Tree_RevealSelected(ctx, tree[:], "level-list", "level-list-scroll", s.settings.rowHeight)
	list, press := rowList(ctx, "level-list", rows[:], s.settings.rowHeight)
	if press.row >= 0 {
		name := rows[press.row].row.label
		// A double-click focuses the level; a right press selects it, then its menu opens
		if press.double do skald.send(ctx, Msg(Level_Row_Clicked{level = name, double = true}))
		if press.right {
			skald.send(ctx, Msg(Level_Row_Clicked{level = name}))
			skald.send(ctx, Msg(Context_Menu_Opened{at = ctx.input.mouse_pos, target = Ctx_Level{level = levels[press.row]}}))
			ctx.input.mouse_pressed[.Right] = false
		}
	}
	append(&parts, skald.flex(1, skald.scroll(ctx, {0, 0}, list, id = skald.hash_id("level-list-scroll"), reveal_focus = false)))
	return parts[:]
}

// A layer type's icon in the Layers sidebar and the Layers tab's list
LevelLayer_Icon :: proc(layerType: string) -> string {
	switch layerType {
	case "IntGrid":   return ICON_GRID
	case "Tiles":     return ICON_IMAGE
	case "Entities":  return ICON_CUBE
	case "AutoLayer": return ICON_WAND
	}
	return ICON_LAYERS
}

/*
The Layers sidebar's content: the header, then the selected level's layers (or the project's
layer definitions) and the selected layer's palette. A row dragged moves the layer (the release
sends `Layer_Move` by the rows it crossed), as the scene tree's rows move nodes.
*/
@(private="file")
levelLayersPart :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	th := ctx.theme
	parts := make([dynamic]skald.View, context.temp_allocator)
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	if doc == nil || doc.problem != "" {
		append(&parts, panelHeader(ctx, ICON_LAYERS, "Layers"), skald.divider(ctx))
		append(&parts, placeholder(ctx, "The selected level's layers show here."))
		return parts[:]
	}
	main := LDtkDoc_Main(doc)
	level := s.level.level != "" ? LDtkDoc_FindLevel(doc, s.level.level) : -1
	selectedDef := LevelMode_LayerDef(s, doc)
	selectedUid := selectedDef >= 0 ? Json_Int(main, Json_Get(main, selectedDef, "uid"), -1) : -1
	textWidth := sidebarTextWidth(s, ctx, true)
	rowHeight := s.settings.rowHeight

	// The rows: the level's layer instances (their visibility), else the definitions
	Layer :: struct {
		uid: int,
		name, type: string,
		visible, hasEye: bool,
	}
	layers := make([dynamic]Layer, context.temp_allocator)
	levelIid := ""
	if level >= 0 {
		_, levelIid = LDtkDoc_LevelNames(doc, level)
		file, array := LDtkDoc_LayerInstances(doc, level)
		json := LDtkDoc_Json(doc, file)
		for li in Json_Items(json, array) {
			uid := Json_Int(json, Json_Get(json, li, "layerDefUid"), -1)
			append(&layers, Layer{uid, Json_String(json, Json_Get(json, li, "__identifier")), Json_String(json, Json_Get(json, li, "__type")), Json_Bool(json, Json_Get(json, li, "visible"), true), true})
		}
	}
	if len(layers) == 0 {
		for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
			append(&layers, Layer{Json_Int(main, Json_Get(main, d, "uid"), -1), Json_String(main, Json_Get(main, d, "identifier")), Json_String(main, Json_Get(main, d, "__type")), true, false})
		}
	}
	append(&parts, panelHeader(ctx, ICON_LAYERS, level >= 0 ? fmt.tprintf("Layers: %s", s.level.level) : "Layers (every level)"), skald.divider(ctx))

	rows := make([dynamic]ListRow, context.temp_allocator)
	tree := make([dynamic]ColoredTreeRow, context.temp_allocator)
	// The layers' places (in `layers`) of the rows shown (hidden ones aren't)
	shown := make([dynamic]int, context.temp_allocator)
	for layer, i in layers {
		selected := layer.uid == selectedUid
		// LDtk's layer options: hidden from the list (`hideInList`; still in its place for drags),
		// its color (`uiColor`): the icon's
		def := LDtkDoc_DefByUid(doc, "layers", layer.uid)
		if Json_Bool(main, Json_Get(main, def, "hideInList")) && !selected do continue
		row := ColoredTreeRow{label = strings.clone(layer.name, context.temp_allocator), icon = LevelLayer_Icon(layer.type), selected = selected}
		if uiColor, hasColor := LDtk_ParseColor(Json_String(main, Json_Get(main, def, "uiColor"))); hasColor do row.iconColor = skald.rgb(u32(uiColor))
		// An IntGrid layer with auto-layer rules: the rules' icon after its name
		if def >= 0 && layer.type == "IntGrid" && Json_Count(main, Json_Get(main, def, "autoRuleGroups")) > 0 do row.badge = ICON_WAND
		eyeKey := fmt.tprintf("level-layer-eye-%d", i)
		eyeId := skald.hash_id(eyeKey)
		trailing := make([dynamic]skald.View, context.temp_allocator)
		if layer.hasEye {
			edit := LDtk_Edit{op = .Layer_Visible, file = strings.clone(file, context.temp_allocator), level = strings.clone(levelIid, context.temp_allocator), def = layer.uid, flag = !layer.visible}
			// Muted, more so when the layer is hidden
			eyeColor := selected && skald.widget_has_focus(ctx, skald.hash_id("level-layers")) ? th.color.on_primary : th.color.fg_muted
			if !layer.visible do eyeColor.a *= 0.55
			// A zone (a button would draw its own background over the row's): a press toggles it
			if skald.widget_hovered(ctx, eyeId) && !skald.mouse_over_overlay(ctx) {
				skald.cursor_request(ctx, .Pointer)
				if ctx.input.mouse_pressed[.Left] && !layerRowDrag.active do skald.send(ctx, Msg(edit))
				eyeColor = th.color.fg
			}
			eyeText := new(skald.View, context.temp_allocator)
			eyeText^ = skald.col(skald.text(layer.visible ? ICON_EYE : ICON_EYE_SLASH, eyeColor, th.font.size_md), padding = th.spacing.xs)
			eye := skald.View_Zone{id = eyeId, child = eyeText}
			append(&trailing, skald.tooltip(ctx, eye, layer.visible ? fmt.tprintf("Hide %s in %s (saved in the file, as LDtk's eye)", layer.name, s.level.level) : fmt.tprintf("Show %s in %s", layer.name, s.level.level),
				id = skald.hash_id(fmt.tprintf("%s-tip", eyeKey))))
		}
		append(&rows, ListRow{row = row, key = fmt.tprintf("level-layer-row-%d", i), pick = Msg(Level_Layer_Picked(layer.uid)), trailing = trailing[:], exclude = layer.hasEye ? []skald.Widget_ID{eyeId} : nil})
		append(&tree, row)
		append(&shown, i)
	}
	Tree_RevealSelected(ctx, tree[:], "level-layers", "level-layers-scroll", rowHeight)
	list, press := rowList(ctx, "level-layers", rows[:], rowHeight)
	// A row dragged (the scene tree's way: TREE_DRAG_THRESHOLD past the press) moves the layer
	drag := &layerRowDrag
	if press.row >= 0 && !press.right {
		drag^ = {pressed = true, def = layers[shown[press.row]].uid, from = shown[press.row], to = shown[press.row], start = ctx.input.mouse_pos}
	}
	indicator := skald.View(skald.View_Spacer{size = 0})
	if drag.pressed {
		listRect := lastRect(ctx, skald.hash_id("level-layers"))
		mouse := ctx.input.mouse_pos
		d := mouse - drag.start
		if !drag.active && d.x * d.x + d.y * d.y >= TREE_DRAG_THRESHOLD * TREE_DRAG_THRESHOLD do drag.active = true
		at := clamp(int((mouse.y - listRect.y) / rowHeight), 0, max(len(shown) - 1, 0))
		if len(shown) > 0 do drag.to = shown[at]
		if !ctx.input.mouse_buttons[.Left] {
			if drag.active && drag.to != drag.from {
				skald.send(ctx, Msg(LDtk_Edit{op = .Layer_Move, file = strings.clone(file, context.temp_allocator), def = drag.def, number = f64(drag.to - drag.from)}))
			}
			drag^ = {}
		} else if drag.active {
			skald.cursor_request(ctx, .Move)
			skald.send(ctx, Msg(Frame_Requested{}))
			// Where it goes: a line before (moving up) or after (down) the row under the pointer
			if drag.to != drag.from {
				y := listRect.y + f32(at + (drag.to > drag.from ? 1 : 0)) * rowHeight - 1
				Line :: struct { color: skald.Color }
				line := new_clone(Line{th.color.primary}, context.temp_allocator)
				indicator = skald.overlay({listRect.x, y, listRect.w, 0}, skald.canvas(ctx, line, proc(l: ^Line, p: skald.Canvas_Painter) {
					skald.draw_rect(p.r, p.bounds, l.color, 1)
				}, width = listRect.w, height = 2), no_shadow = true, pin = true)
			}
		}
	}
	content := make([dynamic]skald.View, context.temp_allocator)
	append(&content, list)
	if level < 0 && len(layers) > 0 do append(&content, skald.col(skald.text("Select a level to show or hide its layers.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60), padding = th.spacing.sm))
	if len(layers) == 0 do append(&content, skald.col(skald.text("This project has no layers: add them in the Layers tab.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60), padding = th.spacing.sm))
	body := skald.col(..content[:], cross_align = .Stretch)
	// What the selected layer paints with (view_level_palette.odin): LDtk's palette under its
	// layers, which take what their rows need (at most half the sidebar; 40% beside a tileset)
	palette, hasPalette := LevelPalette_View(s, ctx, doc, textWidth)
	if !hasPalette {
		append(&parts, skald.flex(1, skald.scroll(ctx, {0, 0}, body, id = skald.hash_id("level-layers-scroll"), reveal_focus = false)), indicator)
		return parts[:]
	}
	Split :: struct {
		content, palette: skald.View,
		need, share: f32,
	}
	split := new_clone(Split{body, palette, f32(len(rows)) * rowHeight + 4, LevelMode_LayerType(s) == "Tiles" ? 0.4 : 0.5}, context.temp_allocator)
	append(&parts, skald.flex(1, skald.sized(ctx, split, proc(ctx: ^skald.Ctx(Msg), d: ^Split, size: [2]f32) -> skald.View {
		listHeight := clamp(d.need, 40, max(size.y * d.share, 40))
		return skald.col(
			skald.scroll(ctx, {0, listHeight}, d.content, id = skald.hash_id("level-layers-scroll"), reveal_focus = false),
			skald.divider(ctx),
			skald.flex(1, d.palette),
			cross_align = .Stretch,
		)
	})), indicator)
	return parts[:]
}

// A level's row right-clicked in the Levels sidebar (its index in the Level mode's document: no
// string, the menu's target outlives the frame)
Ctx_Level :: struct {
	level: int,
	// The canvas's menu (level_world_tools.odin): the world point clicked
	world: [2]f32,
	canvas: bool,
}

/*
A level's menu: focus it, open the scene showing it, make one, open it in LDtk; LDtk's edits of
levels (rename, duplicate, delete, depths, another world, a new level: level_world_tools.odin's
`levelMenuEdits`).
*/
LevelMode_MenuItems :: proc(s: ^State, items: ^[dynamic]skald.Menu_Item(Msg), t: Ctx_Level) {
	file := LevelMode_File(s)
	doc := LDtkDoc_Get(s.project.rootPath, file)
	if doc == nil || doc.problem != "" || t.level < 0 || t.level >= len(doc.levels) do return
	identifier, _ := LDtkDoc_LevelNames(doc, t.level)
	level := strings.clone(identifier, context.temp_allocator)
	shown := LevelMode_ScenesShowing(s, file, level)
	index := -1
	for asset, i in s.project.assets do if asset.kind == .LDtk && asset.path == file do index = i
	if t.canvas {
		LevelWorld_MenuItems(s, items, t)
		return
	}
	focused := s.level.focus == level
	append(items,
		skald.Menu_Item(Msg){label = focused ? "Back to the World" : "Focus", msg = Msg(Level_Focus_Changed(focused ? "" : level))},
		skald.Menu_Item(Msg){label = len(shown) > 0 ? fmt.tprintf("Open %s in the Scene Mode", s.project.scenes[shown[0].scene].name) : "Open in the Scene Mode (no scene shows it)", msg = Msg(Level_Open_Showing(level)), disabled = len(shown) == 0},
		skald.Menu_Item(Msg){label = "New Scene with This Level", msg = Msg(Level_Scene_Created{})},
		skald.Menu_Item(Msg){label = "Open in LDtk at This Level", msg = Msg(LDtk_Asset_Open_Requested(index)), disabled = index < 0},
		MENU_SEPARATOR,
	)
	levelMenuEdits(s, items, doc, t.level)
	append(items, MENU_SEPARATOR, skald.Menu_Item(Msg){label = "New Level...", msg = Msg(Level_Spot_Started{})})
}
