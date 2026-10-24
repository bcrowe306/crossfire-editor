package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import e "engine:."
import "gui:skald"

/*
The Level mode (editor_modes.odin): the world editor. Its workspace:

	+-----------+--------------------------------------+--------------+
	| browser   | World: <file>    [file]  Open in LDtk | the level    |
	|           |                                      | selected,    |
	|           |   the LDtk project's levels, laid    | the scenes   |
	|           |   out as in its world                | showing it   |
	|           +--------------------------------------+              |
	| preview   | bottom panel: LDtk, Console, Output  |              |
	+-----------+--------------------------------------+--------------+

The world map is the browser's (`Preview_RenderLDtk` in its own slot, `.Level`): hovering a level
outlines it, a click selects it (`Level_Map_Clicked`), a double-click opens it in the Scene mode
(the scene whose LDtkLevel node shows it: `LevelMode_ScenesShowing`). The panel on the right says
what the selected level is and which scenes show it, opens them (`Level_Scene_Opened`), or makes a
scene showing it (`Level_Scene_Created`, a `.Project` undo step). The bottom panel's **LDtk** tab
(`LevelMode_LDtkTab`) is a summary of the file's definitions for now: editing them, written back
into the .ldtk file, is TODO.md's next item.

State (`State.level`): its panel sizes (`layout`, `Mode_Layout`), its bottom tab, the world shown
(`file`, an LDtk asset: "" the project's first; remembered in `.editor/modes.ini`) and the selected
level. Its widgets: `level-split-left`, `level-split-center-right`, `level-split-map-bottom`,
`level-file`, `level-open-ldtk`, `ldtk-map-Level` (the map), `level-info-scroll`,
`level-open-scene-<i>`, `level-new-scene`, `level-manual`, `level-bottom-tabs`.
*/

// The Level mode's state
LevelMode :: struct {
	// Its panels: the browser's width, the level panel's, the bottom panel's height
	layout: Layout,
	// The bottom tab it shows (LDtk, Console or Output)
	bottomTab: BottomTab,
	// The LDtk project shown (an asset's path; "" the project's first; owned)
	file: string,
	// The selected level's identifier ("" none; owned)
	level: string,
}

// The Level mode's panels the first time it shows
LEVEL_LAYOUT_DEFAULT :: Layout{leftWidth = 240, rightWidth = 260, bottomHeight = 170, bottomOpen = true}

// A world picked in the Level mode's header (an LDtk asset's path; the frame's string)
Level_File_Chosen :: distinct string

// A press on the Level mode's world map: on a level (`level`, else "" on none), maybe a double-click
Level_Map_Clicked :: struct {
	file, level: string,
	double: bool,
}

// Open a scene showing the selected level in the Scene mode, its LDtkLevel node selected
Level_Scene_Opened :: struct {
	scene, node: int,
}

// A new scene with an LDtkLevel node showing the selected level, opened in the Scene mode
Level_Scene_Created :: struct {}

// Frees the Level mode's state
LevelMode_Destroy :: proc(level: ^LevelMode) {
	delete(level.file)
	delete(level.level)
	level.file, level.level = "", ""
}

/*
The LDtk project the Level mode shows: its chosen one while the project has it, else the
project's first LDtk asset ("" when there's none).
*/
LevelMode_File :: proc(state: ^State) -> string {
	first := ""
	for asset in state.project.assets {
		if asset.kind != .LDtk do continue
		if asset.path == state.level.file do return asset.path
		if first == "" do first = asset.path
	}
	return first
}

// A scene's LDtkLevel node showing a level
LevelShownIn :: struct {
	scene, node: int,
	// It shows every level of the world, not just this one
	allLevels: bool,
}

/*
The scenes (not components) whose LDtkLevel nodes show a level of an LDtk file: the node naming
it (by identifier or iid, or "" for the file's first level), then those showing the whole world.

Returns:
- The scenes and nodes (temp allocated), the ones naming the level first
*/
LevelMode_ScenesShowing :: proc(state: ^State, file, level: string) -> []LevelShownIn {
	project := LDtkEdit_Project(state.project.rootPath, file)
	first, iid := "", ""
	if project != nil {
		for world in project.worlds do for l in world.levels {
			if first == "" do first = l.identifier
			if l.identifier == level do iid = l.iid
		}
	}
	named := make([dynamic]LevelShownIn, context.temp_allocator)
	whole := make([dynamic]LevelShownIn, context.temp_allocator)
	for &scene, si in state.project.scenes {
		if Scene_IsComponent(&scene) do continue
		for node, ni in scene.nodes {
			if node.kind != .LDtkLevel || node.ldtk.file != file do continue
			if node.ldtk.allLevels {
				append(&whole, LevelShownIn{si, ni, true})
			} else if node.ldtk.level == level || (iid != "" && node.ldtk.level == iid) || (node.ldtk.level == "" && level == first) {
				append(&named, LevelShownIn{si, ni, false})
			}
		}
	}
	append(&named, ..whole[:])
	return named[:]
}

/*
The Level mode's messages (and, while it shows, a level picked on the browser's world map, which
selects it here instead of changing the hidden scene).

Returns:
- A command, and whether `m` was one
*/
LevelMode_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Level_File_Chosen:
		if string(v) == state.level.file do return {}, true
		delete(state.level.file)
		state.level.file = strings.clone(string(v))
		delete(state.level.level)
		state.level.level = ""
		Mode_Save(state)
	case Level_Map_Clicked:
		levelSelect(state, v.file, v.level)
		if !v.double || v.level == "" do return {}, true
		shown := LevelMode_ScenesShowing(state, v.file, v.level)
		if len(shown) == 0 {
			logLine(state, .Info, fmt.aprintf("No scene shows %s yet: New Scene with This Level makes one", v.level))
			return {}, true
		}
		levelOpen(state, shown[0].scene, shown[0].node)
	case LDtk_Level_Picked:
		if state.mode != .Level do return {}, false
		levelSelect(state, v.file, v.level)
	case Level_Scene_Opened:
		levelOpen(state, v.scene, v.node)
	case Level_Scene_Created:
		file := LevelMode_File(state)
		if file == "" || state.level.level == "" do return {}, true
		// After the scenes, before the components
		at := Project_SceneCount(&state.project)
		index := Project_AddScene(&state.project, state.level.level, at)
		if at <= state.currentScene do state.currentScene += 1
		scene := &state.project.scenes[index]
		node := Scene_AddLDtkAt(scene, file, 0, {0, 0})
		delete(scene.nodes[node].ldtk.level)
		scene.nodes[node].ldtk.level = strings.clone(state.level.level)
		logLine(state, .Info, fmt.aprintf("Added scene %s showing level %s of %s", scene.name, state.level.level, filepath.base(file)))
		levelOpen(state, index, node)
	case:
		return {}, false
	}
	return {}, true
}

// Selects a level on the map (and its file: the browser's map may show another one)
@(private="file")
levelSelect :: proc(state: ^State, file, level: string) {
	if file != state.level.file && file != "" {
		delete(state.level.file)
		state.level.file = strings.clone(file)
		Mode_Save(state)
	}
	delete(state.level.level)
	state.level.level = strings.clone(level)
}

// Opens a scene's LDtkLevel node in the Scene mode
@(private="file")
levelOpen :: proc(state: ^State, scene, node: int) {
	if scene < 0 || scene >= len(state.project.scenes) do return
	Mode_Set(state, .Scene)
	openScene(state, scene)
	state.codeTab = 0
	state.project.scenes[scene].tabClosed = false
	state.selectedNode = node >= 0 && node < len(state.project.scenes[scene].nodes) ? node : -1
}

/*
The Level mode's workspace: the browser, the world map over the bottom panel, the level panel.
Its panels' sizes are its own (`State.level.layout`); the dividers send the messages the Scene
mode's do, which change the shown mode's layout.
*/
levelModeView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	layout := Mode_LayoutOf(s, .Level)^
	layout.workspace = size
	left, right := FittedSidebarWidths(&layout)
	centerWidth := max(size.x - left - right - DIVIDER * 2, MIN_CENTER_WIDTH)
	center: skald.View
	if !layout.bottomOpen {
		center = skald.col(skald.flex(1, levelMapView(s, ctx)), bottomPanelView(s, ctx), cross_align = .Stretch)
	} else {
		center = skald.split(ctx,
			first = levelMapView(s, ctx),
			second = bottomPanelView(s, ctx),
			first_size = max(size.y - FittedBottomHeight(&layout) - DIVIDER, MIN_VIEWPORT_HEIGHT),
			on_resize = proc(v: f32) -> Msg { return Viewport_Resized(v) },
			id = skald.hash_id("level-split-map-bottom"),
			direction = .Column,
			min_first = MIN_VIEWPORT_HEIGHT,
			min_second = MIN_BOTTOM_HEIGHT,
		)
	}
	centerAndRight := skald.split(ctx,
		first = center,
		second = levelInfoView(s, ctx),
		first_size = centerWidth,
		on_resize = proc(v: f32) -> Msg { return Center_Resized(v) },
		id = skald.hash_id("level-split-center-right"),
		min_first = MIN_CENTER_WIDTH,
		min_second = MIN_SIDEBAR_WIDTH,
	)
	return skald.split(ctx,
		first = browserView(s, ctx),
		second = centerAndRight,
		first_size = left,
		on_resize = proc(v: f32) -> Msg { return Left_Resized(v) },
		id = skald.hash_id("level-split-left"),
		min_first = MIN_SIDEBAR_WIDTH,
		min_second = MIN_CENTER_WIDTH + MIN_SIDEBAR_WIDTH + DIVIDER,
	)
}

// The center: a header (the world, a choice of LDtk files, Open in LDtk) over the world map
@(private="file")
levelMapView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	file := LevelMode_File(s)
	if file == "" {
		return skald.col(
			panelHeader(ctx, ICON_MAP, "World"),
			skald.col(
				skald.text("This project has no LDtk levels yet.", th.color.fg, th.font.size_sm),
				skald.text("Draw levels in LDtk (ldtk.io) and import the .ldtk file: its levels show here, laid out as in its world.", th.color.fg_muted, th.font.size_xs, max_width = 420),
				skald.button(ctx, fmt.tprintf("%s  Import...", ICON_PLUS), Msg(Action.Import_Asset), id = skald.hash_id("level-import"),
					bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
				spacing = th.spacing.sm,
				padding = th.spacing.md,
			),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
	actions := make([dynamic]skald.View, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	index := -1
	for asset, i in s.project.assets {
		if asset.kind != .LDtk do continue
		append(&files, asset.path)
		if asset.path == file do index = i
	}
	if len(files) > 1 {
		append(&actions, labeledSelect(ctx, file, Asset_DisplayNames(files[:]), files[:], 0, proc(_: int, path: string) -> Msg {
			return Level_File_Chosen(path)
		}, id = skald.hash_id("level-file"), width = 160))
	}
	append(&actions, panelButton(ctx, "level-open-ldtk", ICON_EXTERNAL, "Open in LDtk", Msg(LDtk_Asset_Open_Requested(index))))
	project := LDtkEdit_Project(s.project.rootPath, file)
	body: skald.View
	if project == nil {
		body = placeholder(ctx, fmt.tprintf("%s can't be read as an LDtk project.", filepath.base(file)))
	} else {
		body = ldtkThumbnailView(ctx, s, .Level, file, "", true, 0, 0, selected = s.level.level)
	}
	return skald.col(
		panelHeader(ctx, ICON_MAP, fmt.tprintf("World: %s", filepath.base(file)), ..actions[:]),
		skald.flex(1, body),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// The right panel: what the mode is, the selected level and the scenes showing it
@(private="file")
levelInfoView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	_, right := FittedSidebarWidths(Mode_LayoutOf(s, .Level))
	width := max(right - th.spacing.sm * 2 - 14, 120)
	rows := make([dynamic]skald.View, context.temp_allocator)
	small :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32, color: skald.Color = {}) -> skald.View {
		return skald.text(text, color == {} ? ctx.theme.color.fg_muted : color, ctx.theme.font.size_xs, max_width = width)
	}
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	file := LevelMode_File(s)
	project := file != "" ? LDtkEdit_Project(s.project.rootPath, file) : nil
	level: ^e.LDtkLevel
	if project != nil && s.level.level != "" {
		for &world in project.worlds do for &l in world.levels do if l.identifier == s.level.level do level = &l
	}
	switch {
	case project == nil:
		append(&rows, small(ctx, "Levels show here once the project has an LDtk file.", width))
	case level == nil:
		levels := 0
		for world in project.worlds do levels += len(world.levels)
		append(&rows, skald.text(fmt.tprintf("%d level%s", levels, levels == 1 ? "" : "s"), th.color.fg, th.font.size_sm))
		append(&rows, small(ctx, "Click a level on the map to select it, double-click to open it in the Scene mode.", width))
	case:
		append(&rows, skald.text(fmt.tprintf("%s  %s", ICON_MAP, level.identifier), th.color.fg, th.font.size_sm, max_width = width))
		entities := 0
		for l in level.layers do entities += len(l.entities)
		append(&rows, small(ctx, fmt.tprintf("%.0f x %.0f px, at %.0f, %.0f in the world", level.size.x, level.size.y, level.world.x, level.world.y), width))
		append(&rows, small(ctx, fmt.tprintf("%d layer%s, %d entit%s, %d field%s, %d neighbour%s", len(level.layers), len(level.layers) == 1 ? "" : "s",
			entities, entities == 1 ? "y" : "ies", len(level.fields), len(level.fields) == 1 ? "" : "s", len(level.neighbours), len(level.neighbours) == 1 ? "" : "s"), width))
		append(&rows, skald.spacer(th.spacing.xs))
		shown := LevelMode_ScenesShowing(s, file, level.identifier)
		if len(shown) == 0 {
			append(&rows, small(ctx, "No scene shows this level.", width))
			append(&rows, button(ctx, "level-new-scene", fmt.tprintf("%s  New Scene with This Level", ICON_PLUS), Msg(Level_Scene_Created{})))
		} else {
			append(&rows, small(ctx, "Shown in:", width))
			for at, i in shown {
				scene := &s.project.scenes[at.scene]
				label := fmt.tprintf("%s  %s (%s%s)", ICON_ARROW_RIGHT, scene.name, scene.nodes[at.node].name, at.allLevels ? ", the whole world" : "")
				append(&rows, button(ctx, fmt.tprintf("level-open-scene-%d", i), label, Msg(Level_Scene_Opened{at.scene, at.node})))
			}
		}
	}
	// What this mode is
	append(&rows, skald.spacer(th.spacing.sm), skald.divider(ctx), skald.spacer(th.spacing.xs),
		skald.text("Level mode", th.color.fg, th.font.size_sm),
		small(ctx, "Your game's world: the levels of an LDtk project, laid out as they are in it. Open a level in the Scene mode to place nodes, scripts and components around it.", width),
		small(ctx, "Editing levels here (layers, entities, fields, links, saved into the .ldtk file) comes next; draw them in LDtk meanwhile: saves there show here at once.", width),
		button(ctx, "level-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("level_mode"))))
	return skald.col(
		panelHeader(ctx, ICON_CIRCLE_INFO, "Level"),
		skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("level-info-scroll"))),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

/*
The bottom panel's LDtk tab: for now what the file defines (layers, entity types, enums, tilesets,
worlds), read only. TODO.md's next item makes it the editor of those, saved into the .ldtk file.
*/
LevelMode_LDtkTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	file := LevelMode_File(s)
	project := file != "" ? LDtkEdit_Project(s.project.rootPath, file) : nil
	if project == nil do return placeholder(ctx, "The LDtk tab shows the world's LDtk project: import an .ldtk file first.")
	count :: proc(n: int, one, many: string) -> string { return fmt.tprintf("%d %s", n, n == 1 ? one : many) }
	levels := 0
	for world in project.worlds do levels += len(world.levels)
	names :: proc(list: []string) -> string { return len(list) == 0 ? "none" : strings.join(list, ", ", context.temp_allocator) }
	layers := make([dynamic]string, context.temp_allocator)
	for l in project.layers do append(&layers, fmt.tprintf("%s (%v)", l.identifier, l.type))
	entities := make([dynamic]string, context.temp_allocator)
	for d in project.entities do append(&entities, d.identifier)
	enums := make([dynamic]string, context.temp_allocator)
	for d in project.enums do append(&enums, d.identifier)
	line :: proc(ctx: ^skald.Ctx(Msg), title, text: string) -> skald.View {
		th := ctx.theme
		return skald.row(
			skald.text(title, th.color.fg, th.font.size_xs, max_width = 110),
			skald.text(text, th.color.fg_muted, th.font.size_xs, max_width = 900),
			spacing = th.spacing.sm,
		)
	}
	return skald.scroll(ctx, {0, 0}, skald.col(
		skald.text(fmt.tprintf("%s: LDtk %s, %s, %s", filepath.base(file), project.jsonVersion, count(len(project.worlds), "world", "worlds"), count(levels, "level", "levels")), th.color.fg, th.font.size_sm),
		line(ctx, "Layers", names(layers[:])),
		line(ctx, "Entity types", names(entities[:])),
		line(ctx, "Enums", names(enums[:])),
		line(ctx, "Tilesets", count(len(project.tilesets), "tileset", "tilesets")),
		skald.text("Editing these here (layers, entities, collisions, links, level fields, enums, the world), saved into the .ldtk file, comes next.", th.color.fg_muted, th.font.size_xs, max_width = 600),
		spacing = th.spacing.xs,
		padding = th.spacing.sm,
	), id = skald.hash_id("level-ldtk-scroll"))
}

/*
The status bar's middle in the Level mode: the world and the selected level.
*/
LevelMode_Status :: proc(s: ^State) -> (world, level: string) {
	file := LevelMode_File(s)
	world = file == "" ? "World: none" : fmt.tprintf("World: %s", filepath.base(file))
	level = s.level.level == "" ? "Level: none selected" : fmt.tprintf("Level: %s", s.level.level)
	return
}
