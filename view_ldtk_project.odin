package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

/*
The Level mode's World, Level and Project tabs (phase 5 of TODO.md's "LDtk level editor"): LDtk's
world panel (WorldPanel.hx, worldPanel.html), level form (LevelInstanceForm.hx,
levelInstanceForm.html) and project panel (EditProject.hx, editProject.html) as the tabs' rows.
Every control sends an `LDtk_Edit` (ldtk_level_ops.odin, ldtk_project_ops.odin): one undo step.

The World tab's list is the worlds (its toolbar row: Add a World, Delete, New Level), the Project
tab has none (its toolbar row: Save). Widget keys: World: `ldtk-world-add`, `ldtk-world-delete`,
`ldtk-world-new-level`, `ldtk-world-name`, `ldtk-world-iid-copy`,
`ldtk-world-default-w` / `-h`, `ldtk-world-depth-prev` / `-next`, `ldtk-world-up-<i>` / `-down-<i>`; Level: `ldtk-level-identifier`, `ldtk-level-auto`,
`ldtk-level-iid-copy`, `ldtk-level-depth`, `ldtk-level-further` / `-closer`, `ldtk-level-x` /
`-y`, `ldtk-level-w` / `-h`, `ldtk-level-resize`, `ldtk-level-bg`, `ldtk-level-bg-default`,
`ldtk-level-bg-image`, `ldtk-level-bg-pos`, `ldtk-level-pivot-<x>-<y>` (Duplicate and Delete:
the toolbar row's `ldtk-level-duplicate`, `-delete`); Project: `ldtk-project-<key>` (its settings by LDtk's JSON key),
`ldtk-project-flag-<Flag>`, `ldtk-project-command-<i>` / `-when-<i>` / `-up-<i>` /
`-remove-<i>`, `ldtk-project-command-add`, `ldtk-project-save`.
*/

// The World tab: the worlds (LDtk's Multi-worlds), the shown one's name, layout, grids and new
// levels' size, its depths, its levels' places and order
LDtkProject_WorldTab :: proc(c: ^LDtkTabCtx) {
	tk := uiTokens(c.ctx)
	s := c.s
	doc := c.doc
	main := c.main
	wi := c.world
	multi := LDtkDoc_MultiWorlds(doc)
	worldName, worldIid := LDtkDoc_WorldNames(doc, wi)
	// The list: the worlds (one without LDtk's Multi-worlds); a pick shows it on the canvas and in
	// the Levels sidebar
	for _, w in doc.worlds {
		name, iid := LDtkDoc_WorldNames(doc, w)
		row := ColoredTreeRow{label = strings.clone(name, context.temp_allocator), icon = ICON_GLOBE, iconColor = AssetKind_Color(.LDtk), selected = w == wi}
		tabListItem(c, row, Msg(Level_World_Chosen(strings.clone(iid, context.temp_allocator))))
	}
	add := tabBase(c, .World_Added)
	add.entity = LDtk_NewIid()
	del := tabBase(c, .World_Removed)
	del.world = wi
	tabTool(c, "ldtk-world-add", ACTION_ICONS[.Add], "Add a world (LDtk's Multi-worlds: turns it on, the project's levels becoming its first world's)", Msg(add), label = "World")
	tabTool(c, "ldtk-world-delete", ACTION_ICONS[.Delete], "Delete this world and its levels", Msg(del), disabled = len(doc.worlds) <= 1)
	tabTool(c, "ldtk-world-new-level", s.level.spot ? ICON_CROSSHAIRS : ACTION_ICONS[.Add], s.level.spot ? "Picking the new level's spot on the canvas (Esc cancels)" : "New Level: pick its spot on the canvas",
		Msg(Level_Spot_Started{cancel = s.level.spot}), label = "Level", on = s.level.spot)
	worldLevelCount := len(LevelMode_WorldLevels(s, doc))
	c.list.text = fmt.tprintf("%s: %d level%s", worldName, worldLevelCount, worldLevelCount == 1 ? "" : "s")
	if !multi do tabNote(c, "One world (LDtk's Multi-worlds is off): Add a World turns it on, the project's levels becoming its first world's.")
	name := tabBase(c, .World_Set)
	name.world, name.key = wi, "identifier"
	if multi {
		tabRow(c, "Name", tabTextField(c, "ldtk-world-name", worldName, name), "The world's identifier (unique among the project's worlds)")
	}
	tabRow(c, "IID", skald.row(uiText(c.ctx.theme, .Muted, worldIid, max_width = max(c.controlWidth - tk.fieldXS, tk.fieldXS)),
		smallButton(c, "ldtk-world-iid-copy", ACTION_ICONS[.Copy], Msg(Text_Copied(strings.clone(worldIid, context.temp_allocator)))), spacing = tk.xs, cross_align = .Center),
		"The world's unique id (entity references and the table of contents name it); the button copies it")
	layout := LDtkDoc_WorldLayout(doc, wi)
	e := tabBase(c, .World_Layout)
	e.world = wi
	layouts := []string{"Free", "GridVania", "LinearHorizontal", "LinearVertical"}
	labels := []string{"Free (anywhere)", "GridVania (a world grid)", "Horizontal (one after the other)", "Vertical (one after the other)"}
	tabRow(c, "Layout", tabChoiceField(c, "ldtk-world-layout", layout, labels, layouts, e), "How the levels are placed: anywhere, on a world grid, or in a line by their order (changing it moves every level, as in LDtk)")
	grid := LDtkDoc_WorldGrid(doc, wi)
	if layout == "GridVania" {
		e.op = .World_Grid_Width
		tabNumberRow(c, "Grid width", "ldtk-world-grid-w", "The world grid's cells, in pixels (levels move with it)", e, f64(grid.x), 16, 0, 1, 100000)
		e.op = .World_Grid_Height
		tabNumberRow(c, "Grid height", "ldtk-world-grid-h", "The world grid's cell height", e, f64(grid.y), 16, 0, 1, 100000)
	}
	size := LDtkDoc_WorldLevelSize(doc, wi)
	dw := tabBase(c, .World_Set)
	dw.world, dw.key = wi, "defaultLevelWidth"
	tabNumberRow(c, "New level width", "ldtk-world-default-w", "New levels' width in pixels (on the world grid in GridVania)", dw, f64(size.x), 16, 0, 1, 9999)
	dw.key = "defaultLevelHeight"
	tabNumberRow(c, "New level height", "ldtk-world-default-h", "New levels' height", dw, f64(size.y), 16, 0, 1, 9999)
	// World depths (LDtk's world layers)
	lo, hi := LevelMode_Depths(s, doc)
	if lo != hi {
		depth := LevelMode_Depth(s, doc)
		tabRow(c, "Depth shown", skald.row(
			smallButton(c, "ldtk-world-depth-prev", ICON_ARROW_DOWN, Msg(Level_Depth_Shown{step = -1}), disabled = depth <= lo),
			uiText(c.ctx.theme, .Value, fmt.tprintf("%d (of %d to %d)", depth, lo, hi)),
			smallButton(c, "ldtk-world-depth-next", ICON_ARROW_UP, Msg(Level_Depth_Shown{step = 1}), disabled = depth >= hi),
			spacing = tk.s, cross_align = .Center), "The world depth the canvas shows (PgUp / PgDn); the other depths' levels are faded and can't be picked")
	}
	tabHeading(c, "Levels")
	if s.level.spot do tabNote(c, "Click the canvas where the new level goes (Esc cancels).")
	linear := layout == "LinearHorizontal" || layout == "LinearVertical"
	levels := LevelMode_WorldLevels(s, doc)
	for i, at in levels {
		lname, iid := LDtkDoc_LevelNames(doc, i)
		rect := LDtkDoc_LevelRect(doc, i)
		up := tabBase(c, .Level_Sorted)
		up.level = strings.clone(iid, context.temp_allocator)
		up.number = f64(at - 1)
		down := up
		down.number = f64(at + 1)
		order := skald.row(
			smallButton(c, fmt.tprintf("ldtk-world-up-%d", at), ACTION_ICONS[.Move_Up], Msg(up), disabled = at == 0),
			smallButton(c, fmt.tprintf("ldtk-world-down-%d", at), ACTION_ICONS[.Move_Down], Msg(down), disabled = at == len(levels) - 1),
			uiText(c.ctx.theme, .Muted, fmt.tprintf("%.0f x %.0f px%s", rect[2], rect[3], LDtkDoc_LevelDepth(doc, i) != 0 ? fmt.tprintf(", depth %d", LDtkDoc_LevelDepth(doc, i)) : "")),
			spacing = tk.xs, cross_align = .Center)
		tabRow(c, lname, order, linear ? "The level's place in the world's order (a linear world places them by it)" : "The level's place in the world's order (automatic names count it)")
		if linear do continue
		move := tabBase(c, .Level_X)
		move.level = strings.clone(iid, context.temp_allocator)
		step := layout == "GridVania" ? f64(grid.x) : 16
		tabNumberRow(c, fmt.tprintf("%s X", lname), fmt.tprintf("ldtk-world-x-%d", i), "Where the level's left edge is in the world (GridVania: snapped to the grid)", move, rect[0], step, 0, -1000000, 1000000)
		move.op = .Level_Y
		tabNumberRow(c, fmt.tprintf("%s Y", lname), fmt.tprintf("ldtk-world-y-%d", i), "Where its top edge is", move, rect[1], layout == "GridVania" ? f64(grid.y) : 16, 0, -1000000, 1000000)
	}
	tabNote(c, fmt.tprintf("This file is LDtk %s. Levels are added, copied, resized and removed in the Levels sidebar's and the canvas's menus, and the Level tab.", Json_String(main, Json_Get(main, Json_Root(main), "jsonVersion"))))
}

/*
The selected level's settings (LDtk's level form): its name and automatic naming, iid, depth, world
place, size, background color and image (Duplicate / Delete are on the tab's toolbar row).
*/
LDtkProject_LevelSettings :: proc(c: ^LDtkTabCtx) {
	tk := uiTokens(c.ctx)
	s := c.s
	ctx := c.ctx
	th := ctx.theme
	doc := c.doc
	main := c.main
	level := c.level
	entry := doc.levels[level].entry
	identifier, iid := LDtkDoc_LevelNames(doc, level)
	l := strings.clone(iid, context.temp_allocator)
	set :: proc(c: ^LDtkTabCtx, level, key: string) -> LDtk_Edit {
		e := tabBase(c, .Level_Set)
		e.level, e.key = level, key
		return e
	}
	auto := Json_Bool(main, Json_Get(main, entry, "useAutoIdentifier"))
	nameKey := "ldtk-level-identifier"
	if s.level.focusField == nameKey {
		skald.widget_focus(ctx, skald.hash_id(nameKey))
		skald.send(ctx, Msg(Level_Field_Focused{}))
	}
	if auto {
		tabRow(c, "Name", uiText(th, .Value, identifier, max_width = c.controlWidth), "The level's identifier: the project's name pattern makes it while Automatic name is on")
	} else {
		tabRow(c, "Name", tabTextField(c, nameKey, identifier, set(c, l, "identifier")), "The level's identifier (cleaned up and made unique, LDtk's way); scenes naming the level follow it")
	}
	tabFlagRow(c, "Automatic name", "ldtk-level-auto", "Named by the project's level name pattern (the Project tab), as LDtk names new levels", set(c, l, "useAutoIdentifier"), auto)
	tabRow(c, "IID", skald.row(uiText(th, .Muted, iid, max_width = max(c.controlWidth - tk.fieldXS, tk.fieldXS)),
		smallButton(c, "ldtk-level-iid-copy", ACTION_ICONS[.Copy], Msg(Text_Copied(l))), spacing = tk.xs, cross_align = .Center), "The level's unique id; the button copies it")
	depth := LDtkDoc_LevelDepth(doc, level)
	further, closer := LDtkDoc_LevelDepthMoves(doc, level)
	fe, ce := tabBase(c, .Level_Depth), tabBase(c, .Level_Depth)
	fe.level, ce.level = l, l
	fe.number, ce.number = 1, -1
	tabRow(c, "Depth", skald.row(
		numberField(ctx, s, "ldtk-level-depth", LDtkNumberTarget{set(c, l, "worldDepth")}, f64(depth), 1, 0, min(c.controlWidth, 120), -100, 100),
		smallButton(c, "ldtk-level-further", fmt.tprintf("%s Further", ICON_ARROW_UP), Msg(fe), disabled = !further),
		smallButton(c, "ldtk-level-closer", fmt.tprintf("%s Closer", ICON_ARROW_DOWN), Msg(ce), disabled = !closer),
		spacing = tk.xs, cross_align = .Center), "The level's world depth (levels of one depth are side by side; others above or below it)")
	rect := LDtkDoc_LevelRect(doc, level)
	layout := LDtkDoc_WorldLayout(doc, doc.levels[level].world)
	if layout == "Free" || layout == "GridVania" {
		grid := LDtkDoc_WorldGrid(doc, doc.levels[level].world)
		move := tabBase(c, .Level_X)
		move.level = l
		tabNumberRow(c, "World X", "ldtk-level-x", "Where the level's left edge is in the world (GridVania: on the grid)", move, rect[0], layout == "GridVania" ? f64(grid.x) : 16, 0, -1000000, 1000000)
		move.op = .Level_Y
		tabNumberRow(c, "World Y", "ldtk-level-y", "Where its top edge is", move, rect[1], layout == "GridVania" ? f64(grid.y) : 16, 0, -1000000, 1000000)
	}
	// The size: typed, then Resize (cells kept where they are, cropped past the new edges)
	draft := [2]int{int(rect[2]), int(rect[3])}
	if s.level.sizeLevel == iid do draft = s.level.sizeDraft
	tabRow(c, "Width", numberField(ctx, s, "ldtk-level-w", LevelSizeTarget(0), f64(draft.x), 16, 0, min(c.controlWidth, 160), 1, 4096), "The level's width in pixels: Resize applies it (the right edge moves)")
	tabRow(c, "Height", numberField(ctx, s, "ldtk-level-h", LevelSizeTarget(1), f64(draft.y), 16, 0, min(c.controlWidth, 160), 1, 4096), "The level's height: Resize applies it (the bottom edge moves)")
	resize := tabBase(c, .Level_Resized)
	resize.level = l
	resize.number3, resize.number4 = f64(draft.x), f64(draft.y)
	changed := draft != [2]int{int(rect[2]), int(rect[3])}
	buttonRow(c, smallButton(c, "ldtk-level-resize", changed ? fmt.tprintf("Resize to %d x %d", draft.x, draft.y) : "Resize", Msg(resize), disabled = !changed))
	if changed do tabNote(c, "What's past the new edges is removed (entities too, unless their type may leave the level). The handles around a focused level resize it from any side.", true)
	// The background
	tabHeading(c, "Background")
	own := Json_Kind(main, Json_Get(main, entry, "bgColor")) == .String
	bg := Json_String(main, Json_Get(main, entry, "__bgColor"))
	tabRow(c, "Color", skald.row(tabColorField(c, "ldtk-level-bg", bg, set(c, l, "bgColor")),
		own ? smallButton(c, "ldtk-level-bg-default", "Default", Msg(set(c, l, "bgColor"))) : uiText(th, .Muted, "(default)"), spacing = tk.xs, cross_align = .Center),
		"The level's background color; Default uses the project's (the Project tab)")
	images := LDtkDefs_Images(s, doc)
	imageLabels := make([dynamic]string, context.temp_allocator)
	imageValues := make([dynamic]string, context.temp_allocator)
	append(&imageLabels, "(none)")
	append(&imageValues, "")
	for img in images {
		append(&imageLabels, filepath.base(img))
		append(&imageValues, img)
	}
	current := Json_String(main, Json_Get(main, entry, "bgRelPath"))
	if current != "" && !sliceHas(images, current) {
		append(&imageLabels, fmt.tprintf("%s (not in the project)", filepath.base(current)))
		append(&imageValues, current)
	}
	tabRow(c, "Image", tabChoiceField(c, "ldtk-level-bg-image", current == "" ? "(none)" : labelOf(imageLabels[:], imageValues[:], current), imageLabels[:], imageValues[:], set(c, l, "bgRelPath")),
		"A picture under the level's layers (the project's images; import one to add it)")
	if current != "" {
		modes := []string{"Unscaled", "Contain", "Cover", "CoverDirty", "Repeat"}
		modeLabels := []string{"Not scaled", "Fit inside (keep the aspect ratio)", "Cover the level (keep the aspect ratio)", "Cover (stretched)", "Repeat"}
		pos := Json_String(main, Json_Get(main, entry, "bgPos"))
		tabRow(c, "Position", tabChoiceField(c, "ldtk-level-bg-pos", labelOf(modeLabels, modes, pos), modeLabels, modes, set(c, l, "bgPos")), "How the picture is scaled to the level")
		px, py := Json_Float(main, Json_Get(main, entry, "bgPivotX"), 0.5), Json_Float(main, Json_Get(main, entry, "bgPivotY"), 0.5)
		tabRow(c, "Pivot", pivotPicker(c, "ldtk-level-pivot", set(c, l, "bgPivot"), px, py), "Which part of the picture shows when it's cropped, and where it sits")
	}
	// Duplicate and Delete are the tab's toolbar row's (view_ldtk_tab.odin's Level tab)
}

// Whether a list holds a string
@(private="file")
sliceHas :: proc(list: []string, value: string) -> bool {
	for x in list do if x == value do return true
	return false
}

/*
LDtk's pivot editor: nine buttons (corners, edges, center) setting `number`, `number2` of the edit
(0, 0.5 or 1 each), the current one highlighted.
*/
@(private)
pivotPicker :: proc(c: ^LDtkTabCtx, key: string, edit: LDtk_Edit, x, y: f64) -> skald.View {
	tk := uiTokens(c.ctx)
	th := c.ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	for py in ([]f64{0, 0.5, 1}) {
		cells := make([dynamic]skald.View, context.temp_allocator)
		for px in ([]f64{0, 0.5, 1}) {
			e := edit
			e.number, e.number2 = px, py
			on := abs(px - x) < 0.01 && abs(py - y) < 0.01
			append(&cells, skald.button(c.ctx, on ? ICON_CIRCLE : " ", Msg(e), id = skald.hash_id(fmt.tprintf("%s-%v-%v", key, px, py)),
				bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg, width = tk.panelButtonWidth,
				padding = {0, 0}, font_size = th.font.size_xs, radius = th.radius.sm))
		}
		append(&rows, skald.row(..cells[:], spacing = tk.xxs))
	}
	label := fmt.tprintf("%.2g, %.2g", x, y)
	return skald.row(skald.col(..rows[:], spacing = tk.xxs), uiText(th, .Muted, label), spacing = tk.s, cross_align = .Center)
}

// The Project tab: the file and its saving, then every option of LDtk's project panel
LDtkProject_ProjectTab :: proc(c: ^LDtkTabCtx) {
	tk := uiTokens(c.ctx)
	main := c.main
	root := Json_Root(main)
	th := c.ctx.theme
	doc := c.doc
	unsaved := LDtkDoc_IsUnsaved(c.s.project.rootPath, c.file)
	text :: proc(c: ^LDtkTabCtx, value: string) -> skald.View {
		return uiText(c.ctx.theme, .Value, value, max_width = c.controlWidth)
	}
	set :: proc(c: ^LDtkTabCtx, key: string) -> LDtk_Edit {
		e := tabBase(c, .Project_Set)
		e.key = key
		return e
	}
	flagOf :: proc(main: ^JsonDoc, key: string) -> bool {
		return Json_Bool(main, Json_Get(main, Json_Root(main), key))
	}
	// The toolbar row (the tab has no list): Save, and whether there's anything to save
	tabTool(c, "ldtk-project-save", ICON_SAVE, actionTip(c.s, "Save the project (the Level mode's edits stay in memory until you save, play or export)", .Save_Project), Msg(Action.Save_Project), label = "Save", disabled = !unsaved)
	c.list.text = fmt.tprintf("%s: %s", filepath.base(c.file), unsaved ? "unsaved edits" : "saved")
	tabRow(c, "File", text(c, c.file), "The LDtk project's file, in the project's assets")
	tabRow(c, "Saved", skald.text(unsaved ? "Unsaved edits (Save is above)" : "Saved", unsaved ? th.color.warning : th.color.fg_muted, th.font.size_sm),
		"The Level mode's edits stay in memory until you save (Ctrl+S), play or export")
	tabRow(c, "LDtk version", text(c, Json_String(main, Json_Get(main, root, "jsonVersion"))), "The LDtk version the file is written for")
	tabRow(c, "Worlds", text(c, fmt.tprintf("%d (%d level%s)", len(doc.worlds), len(doc.levels), len(doc.levels) == 1 ? "" : "s")), "The project's worlds and levels")

	tabHeading(c, "Saving")
	external := LDtkDoc_ExternalLevels(doc)
	tabFlagRow(c, "Separate level files", "ldtk-project-externalLevels", "Each level in its own .ldtkl file in a folder named after the project (for version control); the project file keeps their settings", set(c, "externalLevels"), external)
	if external do tabNote(c, fmt.tprintf("Saved in %s/ (%d file%s)", strings.trim_suffix(filepath.base(c.file), filepath.ext(c.file)), len(doc.files) - 1, len(doc.files) == 2 ? "" : "s"))
	tabFlagRow(c, "Minify JSON", "ldtk-project-minifyJson", "Write the files without spaces or line breaks (smaller, but hard to read and to merge)", set(c, "minifyJson"), flagOf(main, "minifyJson"))
	tabFlagRow(c, "Backups on save", "ldtk-project-backupOnSave", "Copy the project's files into a backup folder on each save, keeping the newest ones", set(c, "backupOnSave"), flagOf(main, "backupOnSave"))
	if flagOf(main, "backupOnSave") {
		tabNumberRow(c, "Backups kept", "ldtk-project-backupLimit", "How many backups are kept (3 to 50)", set(c, "backupLimit"), f64(Json_Int(main, Json_Get(main, root, "backupLimit"), LDTK_BACKUP_LIMIT)), 1, 0, 3, 50)
		tabRow(c, "Backup folder", tabTextField(c, "ldtk-project-backupRelPath", Json_String(main, Json_Get(main, root, "backupRelPath")), set(c, "backupRelPath")),
			"Where backups go, relative to the project file (empty: <project name>/backups)")
	}
	modes := LDTK_IMAGE_EXPORT_MODES
	modeLabels := []string{"No images", "One PNG per layer", "One PNG per level (layers merged)", "One PNG per layer and one per level"}
	mode := Json_String(main, Json_Get(main, root, "imageExportMode"))
	if mode == "" do mode = "None"
	tabRow(c, "Image export", tabChoiceField(c, "ldtk-project-imageExportMode", labelOf(modeLabels, modes, mode), modeLabels, modes, set(c, "imageExportMode")),
		"PNG pictures of the levels written on each save (into <project name>/png), for engines that draw levels as images")
	if mode != "None" {
		tabFlagRow(c, "With backgrounds", "ldtk-project-exportLevelBg", "The pictures include the levels' backgrounds", set(c, "exportLevelBg"), Json_Bool(main, Json_Get(main, root, "exportLevelBg"), true))
		pattern := Json_String(main, Json_Get(main, root, "pngFilePattern"))
		if pattern == "" do pattern = LDtk_DefaultPngPattern(mode)
		tabRow(c, "File names", tabTextField(c, "ldtk-project-pngFilePattern", pattern, set(c, "pngFilePattern")),
			"The pictures' names: %world, %level_name, %level_idx, %layer_name, %layer_idx")
	}
	tabFlagRow(c, "Super simple export", "ldtk-project-simplifiedExport", "Also write each level as a data.json, a CSV per IntGrid layer and PNG pictures (into <project name>/simplified)", set(c, "simplifiedExport"), flagOf(main, "simplifiedExport"))
	tabFlagRow(c, "Tiled export", "ldtk-project-exportTiled", "LDtk also writes Tiled files (TMX) when it saves: kept for LDtk, the editor doesn't write them (LDtk's cover only the first world)", set(c, "exportTiled"), flagOf(main, "exportTiled"))
	tabNote(c, "What these write on Save is in the manual's Project tab section.")

	tabHeading(c, "Names")
	style := Json_String(main, Json_Get(main, root, "identifierStyle"))
	styles := LDTK_IDENTIFIER_STYLES
	styleLabels := []string{`Capitalize ("My_identifier_1")`, `Uppercase ("MY_IDENTIFIER_1")`, `Lowercase ("my_identifier_1")`, `Free (letter case kept)`}
	tabRow(c, "Identifier style", tabChoiceField(c, "ldtk-project-identifierStyle", labelOf(styleLabels, styles, style), styleLabels, styles, set(c, "identifierStyle")),
		"How names are written. Changing it renames every enum, value, layer, entity type, tileset, world and level (one undo step): check your game's importer reads them")
	pattern := Json_String(main, Json_Get(main, root, "levelNamePattern"))
	if pattern == "" do pattern = LDTK_DEFAULT_LEVEL_NAME_PATTERN
	tabRow(c, "Level names", tabTextField(c, "ldtk-project-levelNamePattern", pattern, set(c, "levelNamePattern")),
		"The pattern naming levels with Automatic name: %world, %idx (from 0), %idx1 (from 1), %x, %y, %gx, %gy (GridVania cells), %depth")

	tabHeading(c, "Defaults")
	tabNumberRow(c, "Grid size", "ldtk-project-defaultGridSize", "New layers' grid, the smallest level size", set(c, "defaultGridSize"), f64(LDtkDoc_DefaultGrid(doc)), 1, 0, 1, LDTK_MAX_GRID_SIZE)
	tabNumberRow(c, "Entity width", "ldtk-project-defaultEntityWidth", "New entity types' width", set(c, "defaultEntityWidth"), f64(Json_Int(main, Json_Get(main, root, "defaultEntityWidth"), 16)), 1, 0, 1, LDTK_MAX_GRID_SIZE)
	tabNumberRow(c, "Entity height", "ldtk-project-defaultEntityHeight", "New entity types' height", set(c, "defaultEntityHeight"), f64(Json_Int(main, Json_Get(main, root, "defaultEntityHeight"), 16)), 1, 0, 1, LDTK_MAX_GRID_SIZE)
	tabRow(c, "Entity pivot", pivotPicker(c, "ldtk-project-pivot", set(c, "defaultPivot"), Json_Float(main, Json_Get(main, root, "defaultPivotX")), Json_Float(main, Json_Get(main, root, "defaultPivotY"))),
		"New entity types' pivot")
	tabRow(c, "Workspace color", tabColorField(c, "ldtk-project-bgColor", Json_String(main, Json_Get(main, root, "bgColor")), set(c, "bgColor")), "LDtk's background behind the levels")
	tabRow(c, "Level color", tabColorField(c, "ldtk-project-defaultLevelBgColor", LDtk_FormatColor(LDtkDoc_DefaultLevelBg(doc)), set(c, "defaultLevelBgColor")),
		"Levels' background color unless they have their own")

	tabHeading(c, "Advanced")
	description :: proc(flag: string) -> string {
		switch flag {
		case "MultiWorlds": return "Several worlds: the levels are kept in the file's worlds (off only with one world)"
		case "PrependIndexToLevelFileNames": return "Separate level files named with their index first (0000-Level.ldtkl); not recommended with version control"
		case "ExportPreCsvIntGridFormat": return "Also write IntGrid layers in the old intGrid format (for importers of LDtk 0.8 or older): bigger files"
		case "UseMultilinesType": return `Multiline text fields' type is "Multilines" in the file, not "String"`
		case "ExportOldTableOfContentData": return "The table of contents also lists its entries' old instances array"
		}
		return ""
	}
	for flag in LDTK_ADVANCED_FLAGS {
		e := tabBase(c, .Project_Flag)
		e.key = flag
		on := LDtkDoc_HasFlag(doc, flag)
		label := flag
		switch flag {
		case "MultiWorlds": label = "Multi-worlds"
		case "PrependIndexToLevelFileNames": label = "Index in file names"
		case "ExportPreCsvIntGridFormat": label = "Old IntGrid data"
		case "UseMultilinesType": label = "Multilines type"
		case "ExportOldTableOfContentData": label = "Old table of contents"
		}
		box := skald.checkbox(c.ctx, on, "", e, proc(edit: LDtk_Edit, v: bool) -> Msg {
			x := edit
			x.flag = v
			return x
		}, id = skald.hash_id(fmt.tprintf("ldtk-project-flag-%s", flag)), disabled = flag == "MultiWorlds" && on && len(doc.worlds) > 1)
		tabRow(c, label, box, description(flag))
	}

	tabHeading(c, "Custom commands")
	tabNote(c, "Commands LDtk runs (by hand, after loading, before or after saving), kept in the file for it. The editor doesn't run them: a project file could make it run any program.")
	commands := Json_Items(main, Json_Get(main, root, "customCommands"))
	triggers := LDTK_COMMAND_TRIGGERS
	triggerLabels := []string{"By hand (Ctrl+R in LDtk)", "After loading", "Before saving", "After saving"}
	for cmd, i in commands {
		e := tabBase(c, .Project_Command)
		e.index = i
		e.key = "command"
		tabRow(c, fmt.tprintf("Command %d", i + 1), tabTextField(c, fmt.tprintf("ldtk-project-command-%d", i), Json_String(main, Json_Get(main, cmd, "command")), e), "The command line LDtk runs")
		w := e
		w.key = "when"
		up, rm := e, e
		up.key, up.number = "move", f64(i - 1)
		rm.key = "remove"
		tabRow(c, "Runs", skald.row(
			tabChoiceField(c, fmt.tprintf("ldtk-project-when-%d", i), labelOf(triggerLabels, triggers, Json_String(main, Json_Get(main, cmd, "when"))), triggerLabels, triggers, w),
			smallButton(c, fmt.tprintf("ldtk-project-up-%d", i), ACTION_ICONS[.Move_Up], Msg(up), disabled = i == 0),
			smallButton(c, fmt.tprintf("ldtk-project-remove-%d", i), ACTION_ICONS[.Delete], Msg(rm)),
			spacing = tk.xs, cross_align = .Center), "When LDtk runs it")
	}
	add := tabBase(c, .Project_Command)
	add.key = "add"
	buttonRow(c, smallButton(c, "ldtk-project-command-add", fmt.tprintf("%s  Add a Command", ACTION_ICONS[.Add]), Msg(add)))

	tabHeading(c, "Description")
	tabRow(c, "Sample text", tabTextField(c, "ldtk-project-tutorialDesc", Json_String(main, Json_Get(main, root, "tutorialDesc")), set(c, "tutorialDesc")),
		"A description LDtk shows over the project (its samples' explanations)")
}
