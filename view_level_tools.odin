package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"

/*
The Level mode's tool row (level_mode.odin): it replaces the toolbar there. LDtk's tools for the
selected layer's type, centered in the window, and the play controls at its end. LDtk has no tool
buttons (a left drag paints, a right drag erases, Shift a rectangle, Shift + click fills, Alt
picks: ldtk/src/electron.renderer/Tool.hx and its tool/lt folder), so the row is these, as buttons, per
layer type (LDtk's IntGridTool, TileTool with its Stamp and Random modes, EntityTool):

	IntGrid:   Select, Pencil, Rectangle, Fill, Eraser, Picker
	Tiles:     Select, Stamp, Random, Rectangle, Fill, Eraser, Picker
	Entities:  Select, Place, Eraser, Picker
	AutoLayer: Select (its tiles come from rules: TODO.md's phase 4)

Select (and move) is the canvas as it was: click to select, drag levels and entities. The others
paint the focused level's selected layer (level_paint.odin: phase 2 of TODO.md's "LDtk level
editor"); LDtk's modifiers work with any of them (Shift a rectangle, Shift + a quick click a fill,
Alt picks, the right button erases).

At full size (the design's: LevelMode_Sizes) the row is 75 px with 45 px buttons; narrower, the
toolbar's sizes. When even those don't fit, the tools go into an overflow button's menu
(`level-tool-more`, `Ctx_Level_Tools`), like the toolbar's. The play controls are the toolbar's
(`toolbar-play`, `toolbar-pause`...). Keys: `level-tool-<Tool>`.
*/

// The Level mode's tools
LevelTool :: enum {
	// Select and move levels and entities (the canvas as it is)
	Select,
	// Paint the layer: an IntGrid value, a tile stamp, an entity placed
	Pencil,
	// Tiles: a random tile of the picked ones per cell
	Random,
	Rectangle,
	Fill,
	Eraser,
	// Pick what's under the pointer (its value, tile or entity type)
	Picker,
}

// A tool's look and whether it's built yet
LevelToolInfo :: struct {
	icon, name, about: string,
	// It does something (every tool since phase 2)
	works: bool,
}

LEVEL_TOOLS := [LevelTool]LevelToolInfo{
	.Select    = {ICON_POINTER, "Select", "Select and move: click a level or an entity to select it, drag it to move it", true},
	.Pencil    = {ICON_PENCIL, "Pencil", "Paint the layer's cells with a value (the right button erases)", true},
	.Random    = {ICON_DICE, "Random", "Paint a random tile of the picked ones in each cell (LDtk: R)", true},
	.Rectangle = {ICON_SQUARE, "Rectangle", "Paint a rectangle (LDtk: Shift + drag)", true},
	.Fill      = {ICON_FILL, "Fill", "Fill the area of the same cells (LDtk: Shift + a quick click)", true},
	.Eraser    = {ICON_ERASER, "Eraser", "Erase (LDtk: the right button)", true},
	.Picker    = {ICON_EYEDROPPER, "Picker", "Pick what's under the pointer (LDtk: Alt + click)", true},
}

// The tool picked in the tool row (or its overflow menu)
Level_Tool_Picked :: distinct LevelTool

/*
The selected layer's definition (the Layers sidebar's; the project's first when none is picked).

Returns:
- Its node in the project file's `defs.layers`, -1 when there are none
*/
LevelMode_LayerDef :: proc(s: ^State, doc: ^LDtkDoc) -> int {
	if doc == nil || doc.problem != "" do return -1
	main := LDtkDoc_Main(doc)
	if def := LDtkDoc_DefByUid(doc, "layers", s.level.layerDef); def >= 0 do return def
	items := Json_Items(main, LDtkDoc_Defs(doc, "layers"))
	return len(items) > 0 ? items[0] : -1
}

// The selected layer's type ("IntGrid", "Tiles", "Entities", "AutoLayer"; "" none)
LevelMode_LayerType :: proc(s: ^State) -> string {
	doc := LDtkDoc_Get(s.project.rootPath, LevelMode_File(s))
	def := LevelMode_LayerDef(s, doc)
	if def < 0 do return ""
	main := LDtkDoc_Main(doc)
	return Json_String(main, Json_Get(main, def, "__type"))
}

// The tools of a layer type, in the row's order (LDtk's per layer type: see the file's doc block)
LevelTools_For :: proc(layerType: string) -> []LevelTool {
	@(static, rodata) INTGRID := []LevelTool{.Select, .Pencil, .Rectangle, .Fill, .Eraser, .Picker}
	@(static, rodata) TILES := []LevelTool{.Select, .Pencil, .Random, .Rectangle, .Fill, .Eraser, .Picker}
	@(static, rodata) ENTITIES := []LevelTool{.Select, .Pencil, .Eraser, .Picker}
	@(static, rodata) OTHER := []LevelTool{.Select}
	switch layerType {
	case "IntGrid":  return INTGRID
	case "Tiles":    return TILES
	case "Entities": return ENTITIES
	}
	return OTHER
}

// Whether the selected layer's type has a tool
LevelTool_Available :: proc(s: ^State, tool: LevelTool) -> bool {
	for t in LevelTools_For(LevelMode_LayerType(s)) do if t == tool do return true
	return false
}

// A tool's icon and name for a layer type (the pencil is LDtk's stamp on tiles, a placed entity on entities)
LevelTool_Look :: proc(tool: LevelTool, layerType: string) -> (icon, name, about: string) {
	info := LEVEL_TOOLS[tool]
	icon, name, about = info.icon, info.name, info.about
	if tool == .Pencil do switch layerType {
	case "Tiles":    icon, name, about = ICON_STAMP, "Stamp", "Paint the tiles picked in the tileset (a stamp of several)"
	case "Entities": icon, name, about = ICON_LOCATION, "Place", "Place an entity of the picked type"
	case "IntGrid":  about = "Paint the layer's cells with the picked IntGrid value"
	}
	if tool == .Eraser && layerType == "Entities" do about = "Remove entities and points (LDtk: the right button)"
	if tool == .Picker && layerType == "Entities" do about = "Pick an entity's type, and select it (LDtk: Alt + click)"
	return
}

// The tooltip of a tool: what it does (painting tools work on the focused level)
LevelTool_Tip :: proc(tool: LevelTool, layerType: string) -> string {
	_, name, about := LevelTool_Look(tool, layerType)
	if tool == .Select do return fmt.tprintf("%s: %s", name, about)
	return fmt.tprintf("%s: %s. On the focused level (double-click a level)", name, about)
}

/*
The tool row: the selected layer's tools centered in the window, the play controls at the end.
It's the Level mode's toolbar (view.odin builds it instead of the toolbar there).
*/
LevelTools_View :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	sizes := LevelMode_Sizes(s, th)
	layerType := LevelMode_LayerType(s)
	tools := LevelTools_For(layerType)
	button := sizes.toolButton
	spacing := sizes.compact ? th.spacing.xs : f32(10)
	padding := sizes.compact ? th.spacing.sm : f32(15)
	iconSize := sizes.compact ? th.font.size_md : math.round(th.font.size_md * 1.45)

	// A square button (the design's: 45 px, 10 px corners), its tooltip
	square :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, size, radius, iconSize: f32, active, disabled: bool) -> skald.View {
		th := ctx.theme
		lineHeight := iconSize * 1.25
		if ctx.renderer != nil do lineHeight = skald.view_size(ctx.renderer, skald.text(icon, th.color.fg, iconSize)).y
		b := skald.button(ctx, icon, msg, id = skald.hash_id(key),
			bg = active ? th.color.primary : th.color.elevated, fg = active ? th.color.on_primary : th.color.fg,
			radius = radius, padding = {0, max((size - lineHeight) * 0.5, 1)}, font_size = iconSize, width = size, disabled = disabled)
		return skald.tooltip(ctx, b, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}

	// The play controls: the toolbar's (their keys too)
	running := s.playState == .Playing || s.playState == .Building
	playTip := actionTip(s, "Play", .Play)
	switch s.playState {
	case .Building: playTip = "Building the player..."
	case .Paused:   playTip = actionTip(s, "Resume", .Play)
	case .Playing, .Stopped:
	}
	play := []skald.View{
		square(ctx, "toolbar-play", ICON_PLAY, playTip, Action.Play, button, sizes.toolRadius, iconSize, running, false),
		square(ctx, "toolbar-play-scene", ICON_PLAY_SCENE, actionTip(s, fmt.tprintf("Play %s (the scene open in the Scene mode)", s.project.scenes[s.currentScene].name), .Play_Scene), Action.Play_Scene, button, sizes.toolRadius, iconSize, false, running),
		square(ctx, "toolbar-pause", ICON_PAUSE, actionTip(s, "Pause", .Pause), Action.Pause, button, sizes.toolRadius, iconSize, s.playState == .Paused, s.playState != .Playing),
		square(ctx, "toolbar-stop", ICON_STOP, actionTip(s, "Stop", .Stop), Action.Stop, button, sizes.toolRadius, iconSize, false, s.playState == .Stopped),
		square(ctx, "toolbar-restart", ICON_RESTART, actionTip(s, "Restart: stop the game and play it again", .Restart), Action.Restart, button, sizes.toolRadius, iconSize, false, !Play_CanRestart(s)),
	}
	playWidth := f32(len(play)) * button + f32(len(play) - 1) * spacing

	// What fits: the tools centered in the window (a spacer as wide as the play controls before
	// them), else beside the play controls, else in a menu
	width := Mode_LayoutOf(s, .Level).workspace.x
	toolsWidth := f32(len(tools)) * button + f32(len(tools) - 1) * spacing
	centered := width <= 0 || padding * 2 + playWidth * 2 + toolsWidth + spacing * 4 <= width
	overflow := width > 0 && padding * 2 + playWidth + toolsWidth + spacing * 3 > width

	items := make([dynamic]skald.View, context.temp_allocator)
	if centered do append(&items, skald.spacer(playWidth))
	append(&items, skald.flex(1, skald.spacer(0)))
	if overflow {
		r := lastRect(ctx, skald.hash_id("level-tool-more"))
		append(&items, square(ctx, "level-tool-more", ICON_ELLIPSIS, "The layer's tools", Msg(Context_Menu_Opened{at = {r.x, r.y + r.h}, target = Ctx_Level_Tools{}}),
			button, sizes.toolRadius, iconSize, false, false))
	} else {
		for tool in tools {
			icon, _, _ := LevelTool_Look(tool, layerType)
			works := LEVEL_TOOLS[tool].works
			append(&items, square(ctx, fmt.tprintf("level-tool-%v", tool), icon, LevelTool_Tip(tool, layerType), Msg(Level_Tool_Picked(tool)),
				button, sizes.toolRadius, iconSize, works && s.level.tool == tool, !works))
		}
	}
	append(&items, skald.flex(1, skald.spacer(0)))
	append(&items, ..play)
	return skald.row(..items[:],
		spacing = spacing,
		padding = sizes.toolRow > 0 ? (sizes.toolRow - button) * 0.5 : padding,
		height = sizes.toolRow,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

// The tool row's overflow menu (a narrow window): the layer's tools, the shown one checked
Ctx_Level_Tools :: struct {}

// The overflow menu's items
LevelTools_MenuItems :: proc(s: ^State, items: ^[dynamic]skald.Menu_Item(Msg)) {
	layerType := LevelMode_LayerType(s)
	for tool in LevelTools_For(layerType) {
		_, name, _ := LevelTool_Look(tool, layerType)
		works := LEVEL_TOOLS[tool].works
		label := works ? name : fmt.tprintf("%s (not yet)", name)
		append(items, skald.Menu_Item(Msg){label = strings.clone(label, context.temp_allocator), msg = Msg(Level_Tool_Picked(tool)), disabled = !works, checked = works && s.level.tool == tool})
	}
}
