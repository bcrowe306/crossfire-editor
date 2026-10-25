package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The Level mode's tools (level_mode.odin), on the editor's toolbar (view.odin's `toolbarView`): in
the Level mode they take the place of the viewport's tools, with the toolbar's own buttons, sizes,
grouping and overflow (`Toolbar_Overflow`); the file, undo, play and Export buttons are the
toolbar's. LDtk's tools for the selected layer's type. LDtk has no tool
buttons (a left drag paints, a right drag erases, Shift a rectangle, Shift + click fills, Alt
picks: ldtk/src/electron.renderer/Tool.hx and its tool/lt folder), so the toolbar has these, as buttons, per
layer type (LDtk's IntGridTool, TileTool with its Stamp and Random modes, EntityTool):

	IntGrid:   Select, Pencil, Rectangle, Fill, Eraser, Picker
	Tiles:     Select, Stamp, Random, Rectangle, Fill, Eraser, Picker
	Entities:  Select, Place, Eraser, Picker
	AutoLayer: Select (its tiles come from its rules: the Auto-layer Rules tab)

Select (and move) is the canvas as it was: click to select, drag levels and entities. The others
paint the focused level's selected layer (level_paint.odin: phase 2 of TODO.md's "LDtk level
editor"); LDtk's modifiers work with any of them (Shift a rectangle, Shift + a quick click a fill,
Alt picks, the right button erases).

When the window is too narrow for them, they go into the toolbar's overflow menu (`toolbar-more`,
`LevelTools_MenuItems`), as the viewport's tools do in the Scene mode. Keys: `level-tool-<Tool>`
(the toolbar's own are `toolbar-play`, `toolbar-export`...).
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
	.Random    = {ACTION_ICONS[.Randomize], "Random", "Paint a random tile of the picked ones in each cell (LDtk: R)", true},
	.Rectangle = {ICON_SQUARE, "Rectangle", "Paint a rectangle (LDtk: Shift + drag)", true},
	.Fill      = {ICON_FILL, "Fill", "Fill the area of the same cells (LDtk: Shift + a quick click)", true},
	.Eraser    = {ICON_ERASER, "Eraser", "Erase (LDtk: the right button)", true},
	.Picker    = {ICON_EYEDROPPER, "Picker", "Pick what's under the pointer (LDtk: Alt + click)", true},
}

// The tool picked on the toolbar (or its overflow menu)
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

// The toolbar's overflow menu (a narrow window) in the Level mode lists the layer's tools
// (context_menus.odin's `Ctx_Toolbar_More` with `level`), the shown one checked
LevelTools_MenuItems :: proc(s: ^State, items: ^[dynamic]skald.Menu_Item(Msg)) {
	layerType := LevelMode_LayerType(s)
	for tool in LevelTools_For(layerType) {
		_, name, _ := LevelTool_Look(tool, layerType)
		works := LEVEL_TOOLS[tool].works
		label := works ? name : fmt.tprintf("%s (not yet)", name)
		append(items, skald.Menu_Item(Msg){label = strings.clone(label, context.temp_allocator), msg = Msg(Level_Tool_Picked(tool)), disabled = !works, checked = works && s.level.tool == tool})
	}
}
