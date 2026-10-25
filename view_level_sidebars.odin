package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

/*
The Level mode's sidebars (level_mode.odin), from the user's design:

- **Levels** (left, replacing the project browser): a header, the LDtk file's choice (with several
  in the project) and the world's (with several worlds: LDtk's Multi-worlds), then a row per level
  of the world (a document icon and the name, the selected one highlighted). A click selects the
  level (and the canvas shows it selected), a double-click focuses it (the canvas fits it, as
  LDtk's level view), a right-click opens its menu (`Ctx_Level`). Without an LDtk file: Import...
- **Layers** (right): the selected level's layers, top first (LDtk's order), then the palette of
  the selected layer (view_level_palette.odin: its IntGrid values, its tileset, its entity
  types); a row each: a grip
  to drag it to another place (`Layer_Move`: the definitions' order, every level's with it), its
  name and type, and the eye (LDtk's: the layer instance's `visible`, saved in the file; the engine
  skips hidden layers), dimmed. A click selects the layer: the tools and the Layers tab follow it.
  Without a selected level: the project's layer definitions (no eyes).

Narrower than LEVEL_ONE_SIDEBAR_WIDTH they're one sidebar, the levels over the layers
(`levelSidebarsStackedView`). Rows are the design's 60 px, shorter in a narrow window
(`LevelMode_Sizes`). Keys: `level-row-<i>` (i: the level's place in the world), `level-list-scroll`,
`level-file`, `level-world`, `level-import`, `level-layer-row-<i>`, `level-layer-grip-<i>`,
`level-layer-eye-<i>` (i: the layer's place, top first), `level-layers-scroll`.
*/

// A layer row's grip being dragged: the layer (its definition's uid), where it was, where it goes
// (file state: only the view follows it, the release sends the edit)
@(private="file")
LayerRowDrag :: struct {
	active: bool,
	def, from, to: int,
}
@(private="file")
layerRowDrag: LayerRowDrag

// The Levels sidebar (the wide window's left one)
levelLevelsSidebarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(..levelLevelsPart(s, ctx), cross_align = .Stretch, bg = th.color.bg)
}

// The Layers sidebar (the wide window's right one)
levelLayersSidebarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(..levelLayersPart(s, ctx), cross_align = .Stretch, bg = th.color.bg)
}

// One sidebar (a narrow window): the levels over the layers, each half of it
levelSidebarsStackedView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.flex(1, skald.col(..levelLevelsPart(s, ctx), cross_align = .Stretch)),
		skald.divider(ctx),
		skald.flex(1, skald.col(..levelLayersPart(s, ctx), cross_align = .Stretch)),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// A sidebar's header: its title (the design's 32 px strip) and what's beside it
@(private="file")
sidebarHeader :: proc(s: ^State, ctx: ^skald.Ctx(Msg), title, note: string) -> skald.View {
	th := ctx.theme
	sizes := LevelMode_Sizes(s, th)
	return skald.row(
		skald.text(title, th.color.fg, th.font.size_sm),
		skald.flex(1, skald.spacer(0)),
		skald.text(note, th.color.fg_muted, th.font.size_xs),
		spacing = th.spacing.xs,
		padding = th.spacing.sm,
		height = sizes.header,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

// The width rows' text gets in a sidebar (the narrower of the two in one column)
@(private="file")
sidebarTextWidth :: proc(s: ^State, ctx: ^skald.Ctx(Msg), right: bool) -> f32 {
	layout := Mode_LayoutOf(s, .Level)
	left, rightWidth, one := LevelMode_Sidebars(layout)
	width := right && !one ? rightWidth : left
	return max(width - 90, 60)
}

/*
A row of a sidebar's list: its content on the selected or hovered color, the press reported (a
left press, with the click count; a right press). Rows are zones keyed `key`: their last rect
(inside the list's scroll: its clip too, `skald.widget_hovered`) is what's hit.
*/
@(private="file")
sidebarRow :: proc(ctx: ^skald.Ctx(Msg), key: string, content: skald.View, selected: bool, height: f32, exclude: ..skald.Widget_ID) -> (view: skald.View, pressed, double, right: bool) {
	th := ctx.theme
	id := skald.hash_id(key)
	hovered := skald.widget_hovered(ctx, id)
	for other in exclude do if skald.widget_hovered(ctx, other) do hovered = false
	if hovered {
		pressed = ctx.input.mouse_pressed[.Left]
		double = pressed && ctx.input.mouse_click_count[.Left] >= 2
		right = ctx.input.mouse_pressed[.Right]
	}
	bg := selected ? th.color.primary : hovered ? th.color.elevated : skald.Color{}
	child := new(skald.View, context.temp_allocator)
	child^ = skald.row(content, height = height, padding = th.spacing.sm, cross_align = .Center, bg = bg)
	return skald.View_Zone{id = id, child = child}, pressed, double, right
}

/*
The Levels sidebar's content: the header, the file and world choices, the level rows (or, without
an LDtk file, how to bring one in).
*/
@(private="file")
levelLevelsPart :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	th := ctx.theme
	sizes := LevelMode_Sizes(s, th)
	parts := make([dynamic]skald.View, context.temp_allocator)
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	readable := doc != nil && doc.problem == ""
	levels := readable ? LevelMode_WorldLevels(s, doc) : nil
	append(&parts, sidebarHeader(s, ctx, "Levels", readable ? fmt.tprintf("%d", len(levels)) : ""))
	textWidth := sidebarTextWidth(s, ctx, false)
	if file == "" {
		append(&parts, skald.col(
			skald.text("No LDtk project yet: import an .ldtk file (LDtk, ldtk.io) and its levels show here.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60),
			skald.button(ctx, fmt.tprintf("%s  Import...", ICON_PLUS), Msg(Action.Import_Asset), id = skald.hash_id("level-import"),
				bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
			spacing = th.spacing.sm,
			padding = th.spacing.sm,
		))
		return parts[:]
	}
	// The LDtk file (several in the project) and the world (several in the file)
	choices := make([dynamic]skald.View, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	for asset in s.project.assets do if asset.kind == .LDtk do append(&files, asset.path)
	choiceWidth := textWidth + 60
	if len(files) > 1 {
		append(&choices, labeledSelect(ctx, file, Asset_DisplayNames(files[:]), files[:], 0, proc(_: int, path: string) -> Msg {
			return Level_File_Chosen(path)
		}, id = skald.hash_id("level-file"), width = choiceWidth))
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
		append(&choices, labeledSelect(ctx, shown, names[:], iids[:], 0, proc(_: int, iid: string) -> Msg {
			return Level_World_Chosen(iid)
		}, id = skald.hash_id("level-world"), width = choiceWidth))
	}
	if readable {
		// LDtk's world panel's New level: a spot picked on the canvas (level_world_tools.odin)
		append(&choices, skald.button(ctx, s.level.spot ? fmt.tprintf("%s  Picking a spot... (Esc)", ICON_CROSSHAIRS) : fmt.tprintf("%s  New Level", ICON_PLUS),
			Msg(Level_Spot_Started{cancel = s.level.spot}), id = skald.hash_id("level-new"),
			bg = s.level.spot ? th.color.primary : th.color.surface, fg = s.level.spot ? th.color.on_primary : th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
	}
	if len(choices) > 0 do append(&parts, skald.col(..choices[:], spacing = th.spacing.xs, padding = th.spacing.xs))
	switch {
	case doc == nil:
		append(&parts, placeholder(ctx, fmt.tprintf("%s can't be read.", filepath.base(file))))
		return parts[:]
	case doc.problem != "":
		append(&parts, placeholder(ctx, "It can't be read as an LDtk project (the canvas says why)."))
		return parts[:]
	}
	rows := make([dynamic]skald.View, context.temp_allocator)
	for index, i in levels {
		identifier, _ := LDtkDoc_LevelNames(doc, index)
		selected := identifier == s.level.level
		fg := selected ? th.color.on_primary : th.color.fg
		muted := selected ? th.color.on_primary : th.color.fg_muted
		label := skald.text(identifier, fg, sizes.compact ? th.font.size_sm : th.font.size_md, max_width = textWidth)
		if identifier == s.level.focus do label = skald.row(label, skald.text(ICON_CROSSHAIRS, muted, th.font.size_xs), spacing = th.spacing.xs, cross_align = .Center)
		content := skald.row(
			skald.text(ICON_FILE_LINES, muted, sizes.compact ? th.font.size_sm : th.font.size_lg),
			label,
			spacing = th.spacing.sm,
			cross_align = .Center,
		)
		key := fmt.tprintf("level-row-%d", i)
		row, pressed, double, right := sidebarRow(ctx, key, content, selected, sizes.row)
		name := strings.clone(identifier, context.temp_allocator)
		if pressed do skald.send(ctx, Msg(Level_Row_Clicked{level = name, double = double}))
		if right {
			// The level is selected, then its menu opens
			skald.send(ctx, Msg(Level_Row_Clicked{level = name}))
			skald.send(ctx, Msg(Context_Menu_Opened{at = ctx.input.mouse_pos, target = Ctx_Level{level = index}}))
			ctx.input.mouse_pressed[.Right] = false
		}
		append(&rows, row)
	}
	if len(rows) == 0 do append(&rows, skald.col(skald.text("This world has no levels: New Level adds one.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60), padding = th.spacing.sm))
	list := skald.scroll(ctx, {0, 0}, skald.col(..rows[:], cross_align = .Stretch), id = skald.hash_id("level-list-scroll"))
	append(&parts, skald.flex(1, list))
	return parts[:]
}

/*
The Layers sidebar's content: the header, then the selected level's layers (or the project's
layer definitions). Rows: grip, name and type, eye; a grip's drag moves the layer (the release
sends `Layer_Move` by the rows it crossed).
*/
@(private="file")
levelLayersPart :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	th := ctx.theme
	sizes := LevelMode_Sizes(s, th)
	parts := make([dynamic]skald.View, context.temp_allocator)
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	if doc == nil || doc.problem != "" {
		append(&parts, sidebarHeader(s, ctx, "Layers", ""))
		append(&parts, placeholder(ctx, "The selected level's layers show here."))
		return parts[:]
	}
	main := LDtkDoc_Main(doc)
	level := s.level.level != "" ? LDtkDoc_FindLevel(doc, s.level.level) : -1
	selectedDef := LevelMode_LayerDef(s, doc)
	selectedUid := selectedDef >= 0 ? Json_Int(main, Json_Get(main, selectedDef, "uid"), -1) : -1
	textWidth := sidebarTextWidth(s, ctx, true)

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
	append(&parts, sidebarHeader(s, ctx, "Layers", level >= 0 ? s.level.level : "every level"))

	// A grip's drag: where the pointer is among the rows (the row under it is where the layer goes)
	drag := &layerRowDrag
	if drag.active {
		pointer := ctx.input.mouse_pos.y
		to := 0
		for _, i in layers {
			r := lastRect(ctx, skald.hash_id(fmt.tprintf("level-layer-row-%d", i)))
			if r.h <= 0 do continue
			if pointer >= r.y do to = i
		}
		drag.to = clamp(to, 0, max(len(layers) - 1, 0))
		skald.cursor_request(ctx, .Move)
		if !ctx.input.mouse_buttons[.Left] {
			if drag.to != drag.from {
				skald.send(ctx, Msg(LDtk_Edit{op = .Layer_Move, file = strings.clone(file, context.temp_allocator), def = drag.def, number = f64(drag.to - drag.from)}))
			}
			drag^ = {}
		} else {
			skald.send(ctx, Msg(Frame_Requested{}))
		}
	}

	rows := make([dynamic]skald.View, context.temp_allocator)
	for layer, i in layers {
		selected := layer.uid == selectedUid
		// LDtk's layer options: hidden from the list (`hideInList`; still in its place for drags),
		// its color beside its name (`uiColor`)
		def := LDtkDoc_DefByUid(doc, "layers", layer.uid)
		if Json_Bool(main, Json_Get(main, def, "hideInList")) && !selected do continue
		uiColor, hasColor := LDtk_ParseColor(Json_String(main, Json_Get(main, def, "uiColor")))
		fg := selected ? th.color.on_primary : th.color.fg
		muted := selected ? th.color.on_primary : th.color.fg_muted
		gripKey := fmt.tprintf("level-layer-grip-%d", i)
		eyeKey := fmt.tprintf("level-layer-eye-%d", i)
		gripId, eyeId := skald.hash_id(gripKey), skald.hash_id(eyeKey)
		// The grip: pressed, it starts dragging the layer
		gripText := new(skald.View, context.temp_allocator)
		gripText^ = skald.col(skald.text(ICON_GRIP_LINES, muted, th.font.size_md), padding = 2)
		grip := skald.tooltip(ctx, skald.View_Zone{id = gripId, child = gripText}, "Drag to move the layer up or down (in every level)", id = skald.hash_id(fmt.tprintf("%s-tip", gripKey)))
		if skald.widget_hovered(ctx, gripId) {
			skald.cursor_request(ctx, .Move)
			if ctx.input.mouse_pressed[.Left] && !drag.active do drag^ = {active = true, def = layer.uid, from = i, to = i}
		}
		typeName := layer.type
		if def >= 0 && Json_Count(main, Json_Get(main, def, "autoRuleGroups")) > 0 && typeName == "IntGrid" do typeName = "IntGrid, auto-layer"
		names := skald.col(
			skald.text(layer.name, fg, th.font.size_md, max_width = textWidth),
			sizes.compact ? skald.View(skald.View_Spacer{}) : skald.text(typeName, muted, th.font.size_xs),
			spacing = 0,
		)
		if sizes.compact do names = skald.row(skald.text(layer.name, fg, th.font.size_sm, max_width = textWidth * 0.6), skald.text(typeName, muted, th.font.size_xs, max_width = textWidth * 0.4), spacing = th.spacing.xs, cross_align = .Center)
		items := make([dynamic]skald.View, context.temp_allocator)
		if hasColor do append(&items, skald.col(skald.spacer(0), width = 4, height = sizes.compact ? 16 : 28, bg = skald.rgb(u32(uiColor)), radius = 2))
		append(&items, grip, skald.flex(1, names))
		if layer.hasEye {
			edit := LDtk_Edit{op = .Layer_Visible, file = strings.clone(file, context.temp_allocator), level = strings.clone(levelIid, context.temp_allocator), def = layer.uid, flag = !layer.visible}
			// Dimmed (the design's), more so when the layer is hidden
			eyeColor := muted
			if !layer.visible do eyeColor.a *= 0.55
			// A zone (a button would draw its own background over the row's): a press toggles it
			if skald.widget_hovered(ctx, eyeId) {
				skald.cursor_request(ctx, .Pointer)
				if skald.widget_hovered(ctx, eyeId) && ctx.input.mouse_pressed[.Left] && !drag.active do skald.send(ctx, Msg(edit))
				eyeColor = fg
			}
			eyeText := new(skald.View, context.temp_allocator)
			eyeText^ = skald.col(skald.text(layer.visible ? ICON_EYE : ICON_EYE_SLASH, eyeColor, sizes.compact ? th.font.size_sm : th.font.size_md), padding = th.spacing.xs)
			eye := skald.View_Zone{id = eyeId, child = eyeText}
			append(&items, skald.tooltip(ctx, eye, layer.visible ? fmt.tprintf("Hide %s in %s (saved in the file, as LDtk's eye)", layer.name, s.level.level) : fmt.tprintf("Show %s in %s", layer.name, s.level.level),
				id = skald.hash_id(fmt.tprintf("%s-tip", eyeKey))))
		}
		content := skald.row(..items[:], spacing = th.spacing.sm, cross_align = .Center)
		row, pressed, _, _ := sidebarRow(ctx, fmt.tprintf("level-layer-row-%d", i), content, selected, sizes.row, gripId, eyeId)
		if pressed do skald.send(ctx, Msg(Level_Layer_Picked(layer.uid)))
		// Where a dragged layer goes: a line over (or under) the row
		if drag.active && drag.to == i && drag.to != drag.from {
			line := skald.col(skald.spacer(0), height = 2, bg = th.color.primary)
			if drag.to < drag.from do append(&rows, line, row)
			else do append(&rows, row, line)
			continue
		}
		append(&rows, row)
	}
	if level < 0 && len(layers) > 0 do append(&rows, skald.col(skald.text("Select a level to show or hide its layers.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60), padding = th.spacing.sm))
	if len(layers) == 0 do append(&rows, skald.col(skald.text("This project has no layers: add them in LDtk.", th.color.fg_muted, th.font.size_xs, max_width = textWidth + 60), padding = th.spacing.sm))
	content := skald.col(..rows[:], cross_align = .Stretch)
	// What the selected layer paints with (view_level_palette.odin): LDtk's palette under its
	// layers, which take what their rows need (at most half the sidebar; 40% beside a tileset)
	palette, shown := LevelPalette_View(s, ctx, doc, textWidth)
	if !shown {
		append(&parts, skald.flex(1, skald.scroll(ctx, {0, 0}, content, id = skald.hash_id("level-layers-scroll"))))
		return parts[:]
	}
	Split :: struct {
		content, palette: skald.View,
		need, share: f32,
	}
	split := new_clone(Split{content, palette, f32(len(rows)) * sizes.row + 4, LevelMode_LayerType(s) == "Tiles" ? 0.4 : 0.5}, context.temp_allocator)
	append(&parts, skald.flex(1, skald.sized(ctx, split, proc(ctx: ^skald.Ctx(Msg), d: ^Split, size: [2]f32) -> skald.View {
		listHeight := clamp(d.need, 40, max(size.y * d.share, 40))
		return skald.col(
			skald.scroll(ctx, {0, listHeight}, d.content, id = skald.hash_id("level-layers-scroll")),
			skald.divider(ctx),
			skald.flex(1, d.palette),
			cross_align = .Stretch,
		)
	})))
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
