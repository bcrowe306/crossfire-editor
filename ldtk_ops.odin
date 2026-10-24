package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
The Level mode's edits of the LDtk project (ldtk_doc.odin): one `LDtk_Edit` message per change,
made in the document in memory (Save, Play and exports write it), each an undo step restoring the
document's texts (history.odin's `.Files` scope).

**What an edit changes.** Only the values it changes (`LDtkPatches`: spans of the text replaced),
so everything else in the files stays byte for byte as LDtk wrote it. And what LDtk keeps in step
with them, as LDtk itself would:
- renames update the copies LDtk keeps beside instances (`__identifier` of layer, entity and field
  instances, `__type` of enum fields, the table of contents' entry), enum value renames every
  value using it (`__value`, `realEditorValues`, defaults, tilesets' enum tags);
- a field's value is written twice, as LDtk does: `__value` (what games read) and
  `realEditorValues` (what LDtk edits; empty for the default);
- moved entities get their `__grid`, `__worldX` / `__worldY`; moved levels their entities' world
  positions and every level's `__neighbours` (LDtk's rule: `ldtkNeighbours`); the table of
  contents (`toc`) follows the entities it lists (`refreshToc`);
- a layer's opacity is its instances' `__opacity` too, its grid size their `__gridSize`,
  `__cWid`, `__cHei` (only for layers with nothing drawn: cells would move), its order the
  levels' layer instances' order;
- new things take uids from `nextUid`.
Identifiers are cleaned up as LDtk does (`LDtk_CleanIdentifier`, the project's identifier style)
and must be unique. External levels (`.ldtkl` files) are written where the level's data is. A file
LDtk older than 1.0 wrote isn't edited (LDtk updates it when it saves).

What isn't editable yet (the tab says so): arrays of values, tiles and file paths in fields,
symmetrical entity references, external enums, linear world layouts' level order, a field's or
layer's type.
*/

// What an LDtk_Edit changes
LDtkEditOp :: enum {
	// A layer definition (`def`: its uid): its identifier, opacity, parallax, grid size, place
	// in the list (`number`: -1 up, 1 down)
	Layer_Name,
	Layer_Opacity,
	Layer_Parallax_X,
	Layer_Parallax_Y,
	Layer_Parallax_Scaling,
	Layer_Grid_Size,
	Layer_Move,
	// A layer of the level `level` (iid): shown or hidden (`flag`)
	Layer_Visible,
	// An entity definition (`def`)
	Entity_Name,
	Entity_Width,
	Entity_Height,
	Entity_Color,
	Entity_Pivot_X,
	Entity_Pivot_Y,
	// A field definition (`field`: its uid): its identifier, its default (`text`)
	Field_Name,
	Field_Default,
	// An entity instance (`entity`: its iid): its position, a field's value (`field`, `text`),
	// an entity reference field's target (`text`: the target's iid, "" none)
	Entity_X,
	Entity_Y,
	Entity_Moved,
	Entity_Field,
	Entity_Ref,
	// A level (`level`: its iid): a field's value, its world position (`number`, `number2`)
	Level_Field,
	Level_X,
	Level_Y,
	Level_Moved,
	// An IntGrid layer's value (`def` the layer, `index` the value)
	IntGrid_Name,
	IntGrid_Color,
	// An enum (`def`), one of its values (`index`), a new value (`text`), a new enum (`text`)
	Enum_Name,
	Enum_Value_Name,
	Enum_Value_Color,
	Enum_Value_Added,
	Enum_Added,
	// A world (`world`: its index): its layout (`text`), its grid
	World_Layout,
	World_Grid_Width,
	World_Grid_Height,
}

// An edit of an LDtk project (strings only live for the frame)
LDtk_Edit :: struct {
	op: LDtkEditOp,
	// The .ldtk file (relative to the project)
	file: string,
	world: int,
	// A definition's uid, a field definition's uid, an index (an enum value's, an IntGrid value)
	def, field, index: int,
	// A level's and an entity's iid
	level, entity: string,
	text: string,
	number, number2: f64,
	flag: bool,
}

// A rename an edit made, which scenes may follow (their LDtkLevel nodes name layers and entities)
LDtkRename :: struct {
	kind: enum { None, Layer, Entity },
	from, to: string,
}

// What an edit's second pass brings in step (ldtkCommit)
@(private="file")
LDtkRefresh :: struct {
	// Every level's neighbours, and its entities' world positions
	neighbours, worldPositions: bool,
	// The table of contents
	toc: bool,
}

/*
Applies an edit to an LDtk project's document in memory (`LDtkDoc_Save` writes it).

Inputs:
- root: The project folder
- edit: The edit

Returns:
- "" or why nothing changed; and a rename scenes may follow
*/
LDtkOps_Apply :: proc(root: string, edit: LDtk_Edit) -> (problem: string, rename: LDtkRename) {
	doc := LDtkDoc_Get(root, edit.file)
	if doc == nil do return fmt.tprintf("%s can't be read", edit.file), {}
	if doc.problem != "" do return doc.problem, {}
	if old := LDtkOps_TooOld(doc); old != "" do return old, {}
	main := LDtkDoc_Main(doc)
	rootNode := Json_Root(main)
	minified := Json_Minified(main)
	patches := LDtkPatches{}
	refresh := LDtkRefresh{}
	set :: LDtkPatches_Set
	style := Json_String(main, Json_Get(main, rootNode, "identifierStyle"))

	switch edit.op {
	// Layers
	case .Layer_Name, .Layer_Opacity, .Layer_Parallax_X, .Layer_Parallax_Y, .Layer_Parallax_Scaling, .Layer_Grid_Size:
		def := LDtkDoc_DefByUid(doc, "layers", edit.def)
		if def < 0 do return "no such layer", {}
		#partial switch edit.op {
		case .Layer_Name:
			id, ok := LDtk_CleanIdentifier(edit.text, style)
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			old := Json_String(main, Json_Get(main, def, "identifier"))
			if id == old do return "", {}
			for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if d != def && Json_String(main, Json_Get(main, d, "identifier")) == id do return fmt.tprintf("another layer is named %s", id), {}
			set(&patches, doc, 0, Json_Get(main, def, "identifier"), Json_Quote(id))
			for li in ldtkLayerInstancesOf(doc, edit.def) do set(&patches, doc, li.file, Json_Get(LDtkDoc_Json(doc, li.file), li.node, "__identifier"), Json_Quote(id))
			rename = {.Layer, strings.clone(old, context.temp_allocator), strings.clone(id, context.temp_allocator)}
		case .Layer_Opacity:
			text := Json_FormatNumber(clamp(edit.number, 0, 1), 3)
			set(&patches, doc, 0, Json_Get(main, def, "displayOpacity"), text)
			for li in ldtkLayerInstancesOf(doc, edit.def) do set(&patches, doc, li.file, Json_Get(LDtkDoc_Json(doc, li.file), li.node, "__opacity"), text)
		case .Layer_Parallax_X:
			set(&patches, doc, 0, Json_Get(main, def, "parallaxFactorX"), Json_FormatNumber(clamp(edit.number, -1, 1), 3))
		case .Layer_Parallax_Y:
			set(&patches, doc, 0, Json_Get(main, def, "parallaxFactorY"), Json_FormatNumber(clamp(edit.number, -1, 1), 3))
		case .Layer_Parallax_Scaling:
			set(&patches, doc, 0, Json_Get(main, def, "parallaxScaling"), edit.flag ? "true" : "false")
		case .Layer_Grid_Size:
			if why := LDtkOps_GridSizeLocked(doc, edit.def); why != "" do return why, {}
			grid := clamp(int(math.round(edit.number)), 1, 1024)
			set(&patches, doc, 0, Json_Get(main, def, "gridSize"), fmt.tprint(grid))
			for li in ldtkLayerInstancesOf(doc, edit.def) {
				json := LDtkDoc_Json(doc, li.file)
				rect := LDtkDoc_LevelRect(doc, li.level)
				cw, ch := int(math.ceil(rect[2] / f64(grid))), int(math.ceil(rect[3] / f64(grid)))
				set(&patches, doc, li.file, Json_Get(json, li.node, "__gridSize"), fmt.tprint(grid))
				set(&patches, doc, li.file, Json_Get(json, li.node, "__cWid"), fmt.tprint(cw))
				set(&patches, doc, li.file, Json_Get(json, li.node, "__cHei"), fmt.tprint(ch))
				// An empty IntGrid layer's cells: zeros, as many as the new grid has
				csv := Json_Get(json, li.node, "intGridCsv")
				if Json_Count(json, csv) > 0 {
					zeros := make([]string, cw * ch, context.temp_allocator)
					for &z in zeros do z = "0"
					set(&patches, doc, li.file, csv, Json_Array(..zeros))
				}
				// Entities keep their pixels; their cells follow
				for e in Json_Items(json, Json_Get(json, li.node, "entityInstances")) do ldtkSetGrid(&patches, doc, li.file, e, grid)
			}
		}
	case .Layer_Move:
		// `number` places: -1 up, 1 down, more from a drag in the Layers sidebar
		layers := LDtkDoc_Defs(doc, "layers")
		def := LDtkDoc_DefByUid(doc, "layers", edit.def)
		items := Json_Items(main, layers)
		at, _ := slice.linear_search(items, def)
		steps := int(math.round(edit.number))
		if steps == 0 do steps = edit.number < 0 ? -1 : edit.number > 0 ? 1 : 0
		to := clamp(at + steps, 0, len(items) - 1)
		if def < 0 || to == at do return "", {}
		ldtkMove(&patches, doc, 0, items, at, to)
		// Every level's layer instances are in the definitions' order
		order := make([]int, len(items), context.temp_allocator)
		for d, i in items do order[i] = Json_Int(main, Json_Get(main, d, "uid"), -1)
		for _, level in doc.levels {
			file, array := LDtkDoc_LayerInstances(doc, level)
			if array < 0 do continue
			json := LDtkDoc_Json(doc, file)
			instances := Json_Items(json, array)
			// The instances as the definitions are (LDtk keeps them so); a level that differs is left
			same := len(instances) == len(order)
			if same do for li, i in instances do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) != order[i] do same = false
			if same do ldtkMove(&patches, doc, file, instances, at, to)
		}
	case .Layer_Visible:
		level := LDtkDoc_FindLevel(doc, edit.level)
		if level < 0 do return "no such level", {}
		file, array := LDtkDoc_LayerInstances(doc, level)
		json := LDtkDoc_Json(doc, file)
		for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == edit.def {
			set(&patches, doc, file, Json_Get(json, li, "visible"), edit.flag ? "true" : "false")
		}

	// Entity definitions
	case .Entity_Name, .Entity_Width, .Entity_Height, .Entity_Color, .Entity_Pivot_X, .Entity_Pivot_Y:
		def := LDtkDoc_DefByUid(doc, "entities", edit.def)
		if def < 0 do return "no such entity", {}
		instances := ldtkEntitiesOf(doc, edit.def)
		#partial switch edit.op {
		case .Entity_Name:
			id, ok := LDtk_CleanIdentifier(edit.text, style)
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			old := Json_String(main, Json_Get(main, def, "identifier"))
			if id == old do return "", {}
			for d in Json_Items(main, LDtkDoc_Defs(doc, "entities")) do if d != def && Json_String(main, Json_Get(main, d, "identifier")) == id do return fmt.tprintf("another entity is named %s", id), {}
			set(&patches, doc, 0, Json_Get(main, def, "identifier"), Json_Quote(id))
			for e in instances do set(&patches, doc, e.file, Json_Get(LDtkDoc_Json(doc, e.file), e.node, "__identifier"), Json_Quote(id))
			for entry in Json_Items(main, Json_Get(main, rootNode, "toc")) {
				if Json_String(main, Json_Get(main, entry, "identifier")) == old do set(&patches, doc, 0, Json_Get(main, entry, "identifier"), Json_Quote(id))
			}
			rename = {.Entity, strings.clone(old, context.temp_allocator), strings.clone(id, context.temp_allocator)}
		case .Entity_Width, .Entity_Height:
			key := edit.op == .Entity_Width ? "width" : "height"
			old := Json_Int(main, Json_Get(main, def, key))
			size := clamp(int(math.round(edit.number)), 1, 4096)
			set(&patches, doc, 0, Json_Get(main, def, key), fmt.tprint(size))
			// Instances without a size of their own (the definition's) follow it
			for e in instances {
				json := LDtkDoc_Json(doc, e.file)
				if Json_Int(json, Json_Get(json, e.node, key)) == old do set(&patches, doc, e.file, Json_Get(json, e.node, key), fmt.tprint(size))
			}
			refresh.toc = true
		case .Entity_Color:
			color, ok := LDtk_ParseColor(edit.text)
			if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text), {}
			old := Json_String(main, Json_Get(main, def, "color"))
			set(&patches, doc, 0, Json_Get(main, def, "color"), Json_Quote(LDtk_FormatColor(color)))
			// Instances whose smart color is the definition's
			for e in instances {
				json := LDtkDoc_Json(doc, e.file)
				smart := Json_Get(json, e.node, "__smartColor")
				if strings.equal_fold(Json_String(json, smart), old) do set(&patches, doc, e.file, smart, Json_Quote(LDtk_FormatColor(color)))
			}
		case .Entity_Pivot_X, .Entity_Pivot_Y:
			key := edit.op == .Entity_Pivot_X ? "pivotX" : "pivotY"
			pivot := clamp(edit.number, 0, 1)
			set(&patches, doc, 0, Json_Get(main, def, key), Json_FormatNumber(pivot, 3))
			px := edit.op == .Entity_Pivot_X ? pivot : Json_Float(main, Json_Get(main, def, "pivotX"))
			py := edit.op == .Entity_Pivot_Y ? pivot : Json_Float(main, Json_Get(main, def, "pivotY"))
			for e in instances {
				json := LDtkDoc_Json(doc, e.file)
				set(&patches, doc, e.file, Json_Get(json, e.node, "__pivot"), Json_Array(Json_FormatNumber(px, 3), Json_FormatNumber(py, 3)))
				ldtkSetGridPivot(&patches, doc, e.file, e.node, ldtkInstanceGrid(doc, e), px, py)
			}
		}

	// Field definitions
	case .Field_Name, .Field_Default:
		owner, fieldDef := LDtkDoc_FieldDef(doc, edit.field)
		if fieldDef < 0 do return "no such field", {}
		info := LDtkDoc_FieldInfo(doc, fieldDef)
		users := ldtkFieldInstancesOf(doc, edit.field)
		if edit.op == .Field_Name {
			id, ok := LDtk_CleanIdentifier(edit.text, "Free")
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			if id == info.identifier do return "", {}
			for f in Json_Items(main, Json_Get(main, owner, "fieldDefs")) do if f != fieldDef && Json_String(main, Json_Get(main, f, "identifier")) == id do return fmt.tprintf("another field is named %s", id), {}
			if owner == LDtkDoc_Defs(doc, "levelFields") {
				for f in Json_Items(main, owner) do if f != fieldDef && Json_String(main, Json_Get(main, f, "identifier")) == id do return fmt.tprintf("another level field is named %s", id), {}
			}
			set(&patches, doc, 0, Json_Get(main, fieldDef, "identifier"), Json_Quote(id))
			for u in users do set(&patches, doc, u.file, Json_Get(LDtkDoc_Json(doc, u.file), u.node, "__identifier"), Json_Quote(id))
			// The table of contents' copies of exported fields are named by it
			if Json_Bool(main, Json_Get(main, fieldDef, "exportToToc")) {
				for entry in Json_Items(main, Json_Get(main, rootNode, "toc")) do for data in Json_Items(main, Json_Get(main, entry, "instancesData")) {
					fields := Json_Get(main, data, "fields")
					if member := Json_Get(main, fields, info.identifier); member >= 0 {
						n := main.nodes[member]
						LDtkPatches_Add(&patches, 0, {int(n.keyStart), int(n.keyEnd), Json_Quote(id)})
					}
				}
			}
		} else {
			if info.isArray do return "arrays' defaults aren't editable here yet", {}
			#partial switch info.type {
			case .Int, .Float, .Bool, .String, .Text:
			case: return fmt.tprintf("%v fields' defaults aren't editable here yet", info.type), {}
			}
			override := "null"
			if strings.trim_space(edit.text) != "" {
				_, raw, ok, why := ldtkFieldValue(doc, info, edit.text, minified)
				if !ok do return why, {}
				// realEditorValues' one item is the override
				override = strings.trim_suffix(strings.trim_prefix(raw, "["), "]")
			}
			set(&patches, doc, 0, Json_Get(main, fieldDef, "defaultOverride"), override)
			// Instances using the default show the new one
			newInfo := info
			newInfo.defaultText = ldtkDefaultText(info, override)
			for u in users {
				json := LDtkDoc_Json(doc, u.file)
				if ldtkUsesDefault(json, u.node) do set(&patches, doc, u.file, Json_Get(json, u.node, "__value"), newInfo.defaultText)
			}
			refresh.toc = true
		}

	// Entity instances
	case .Entity_X, .Entity_Y, .Entity_Moved:
		e, found := LDtkDoc_FindEntity(doc, edit.entity)
		if !found do return "no such entity", {}
		json := LDtkDoc_Json(doc, e.file)
		px := Json_Get(json, e.node, "px")
		x, y := Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))
		#partial switch edit.op {
		case .Entity_X: x = int(math.round(edit.number))
		case .Entity_Y: y = int(math.round(edit.number))
		case .Entity_Moved: x, y = int(math.round(edit.number)), int(math.round(edit.number2))
		}
		set(&patches, doc, e.file, px, Json_Array(fmt.tprint(x), fmt.tprint(y)))
		def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
		ldtkSetGridPivot(&patches, doc, e.file, e.node, ldtkInstanceGrid(doc, e), Json_Float(main, Json_Get(main, def, "pivotX")), Json_Float(main, Json_Get(main, def, "pivotY")), {x, y})
		refresh = {worldPositions = true, toc = true}
	case .Entity_Field, .Level_Field:
		file, owner := -1, -1
		if edit.op == .Entity_Field {
			e, found := LDtkDoc_FindEntity(doc, edit.entity)
			if !found do return "no such entity", {}
			file, owner = e.file, e.node
		} else {
			level := LDtkDoc_FindLevel(doc, edit.level)
			if level < 0 do return "no such level", {}
		}
		_, fieldDef := LDtkDoc_FieldDef(doc, edit.field)
		if fieldDef < 0 do return "no such field", {}
		info := LDtkDoc_FieldInfo(doc, fieldDef)
		if why := LDtkOps_FieldLocked(info); why != "" do return why, {}
		// Nothing typed: the default (LDtk's empty value)
		value, raw := info.defaultText, "[]"
		if strings.trim_space(edit.text) != "" {
			v, r, ok, why := ldtkFieldValue(doc, info, edit.text, minified)
			if !ok do return why, {}
			value, raw = v, r
		}
		places := make([dynamic]LDtkDocPlace, context.temp_allocator)
		if edit.op == .Entity_Field do append(&places, LDtkDocPlace{file, owner})
		else do append(&places, ..LDtkDoc_LevelObjects(doc, LDtkDoc_FindLevel(doc, edit.level)))
		found := false
		for place in places {
			json := LDtkDoc_Json(doc, place.file)
			for fi in Json_Items(json, Json_Get(json, place.node, "fieldInstances")) {
				if Json_Int(json, Json_Get(json, fi, "defUid"), -1) != edit.field do continue
				set(&patches, doc, place.file, Json_Get(json, fi, "__value"), value)
				set(&patches, doc, place.file, Json_Get(json, fi, "realEditorValues"), raw)
				found = true
			}
		}
		if !found do return "this field has no value in the file yet: open and save it in LDtk once", {}
		refresh.toc = true
	case .Entity_Ref:
		e, found := LDtkDoc_FindEntity(doc, edit.entity)
		if !found do return "no such entity", {}
		_, fieldDef := LDtkDoc_FieldDef(doc, edit.field)
		if fieldDef < 0 do return "no such field", {}
		info := LDtkDoc_FieldInfo(doc, fieldDef)
		if info.type != .EntityRef do return "not an entity reference", {}
		if why := LDtkOps_FieldLocked(info); why != "" do return why, {}
		value, raw := "null", "[]"
		if edit.text != "" {
			target, ok := LDtkDoc_FindEntity(doc, edit.text)
			if !ok do return "no such target", {}
			if !LDtkOps_RefAllowed(doc, info, e, target) do return "this field can't point at that entity", {}
			value = ldtkRefValue(doc, target, minified)
			raw = Json_Array(Json_Object(minified, {"id", Json_Quote("V_String")}, {"params", Json_Array(Json_Quote(edit.text))}))
		}
		json := LDtkDoc_Json(doc, e.file)
		for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
			if Json_Int(json, Json_Get(json, fi, "defUid"), -1) != edit.field do continue
			set(&patches, doc, e.file, Json_Get(json, fi, "__value"), value)
			set(&patches, doc, e.file, Json_Get(json, fi, "realEditorValues"), raw)
		}
		refresh.toc = true

	// Levels in the world
	case .Level_X, .Level_Y, .Level_Moved:
		level := LDtkDoc_FindLevel(doc, edit.level)
		if level < 0 do return "no such level", {}
		world := doc.levels[level].world
		layout := LDtkDoc_WorldLayout(doc, world)
		if layout == "LinearHorizontal" || layout == "LinearVertical" do return "levels of a linear world are placed by their order: pick Free or GridVania in the World tab to move them", {}
		rect := LDtkDoc_LevelRect(doc, level)
		x, y := int(rect[0]), int(rect[1])
		#partial switch edit.op {
		case .Level_X: x = int(math.round(edit.number))
		case .Level_Y: y = int(math.round(edit.number))
		case .Level_Moved: x, y = int(math.round(edit.number)), int(math.round(edit.number2))
		}
		if layout == "GridVania" {
			grid := LDtkDoc_WorldGrid(doc, world)
			x, y = LDtk_SnapToGrid(x, grid.x), LDtk_SnapToGrid(y, grid.y)
		}
		for place in LDtkDoc_LevelObjects(doc, level) {
			json := LDtkDoc_Json(doc, place.file)
			set(&patches, doc, place.file, Json_Get(json, place.node, "worldX"), fmt.tprint(x))
			set(&patches, doc, place.file, Json_Get(json, place.node, "worldY"), fmt.tprint(y))
		}
		refresh = {neighbours = true, worldPositions = true, toc = true}

	// IntGrid values
	case .IntGrid_Name, .IntGrid_Color:
		def := LDtkDoc_DefByUid(doc, "layers", edit.def)
		if def < 0 do return "no such layer", {}
		value := -1
		for v in Json_Items(main, Json_Get(main, def, "intGridValues")) do if Json_Int(main, Json_Get(main, v, "value"), -1) == edit.index do value = v
		if value < 0 do return "no such value", {}
		if edit.op == .IntGrid_Name {
			text := strings.trim_space(edit.text)
			if text == "" {
				set(&patches, doc, 0, Json_Get(main, value, "identifier"), "null")
				break
			}
			id, ok := LDtk_CleanIdentifier(text, "Free")
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			for v in Json_Items(main, Json_Get(main, def, "intGridValues")) do if v != value && Json_String(main, Json_Get(main, v, "identifier")) == id do return fmt.tprintf("another value is named %s", id), {}
			set(&patches, doc, 0, Json_Get(main, value, "identifier"), Json_Quote(id))
		} else {
			color, ok := LDtk_ParseColor(edit.text)
			if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text), {}
			set(&patches, doc, 0, Json_Get(main, value, "color"), Json_Quote(LDtk_FormatColor(color)))
		}

	// Enums
	case .Enum_Name, .Enum_Value_Name, .Enum_Value_Color, .Enum_Value_Added:
		def := LDtkDoc_DefByUid(doc, "enums", edit.def)
		if def < 0 do return "no such enum", {}
		if Json_Kind(main, Json_Get(main, def, "externalRelPath")) == .String do return "this enum comes from an external file: edit that file", {}
		enumName := Json_String(main, Json_Get(main, def, "identifier"))
		values := Json_Get(main, def, "values")
		#partial switch edit.op {
		case .Enum_Name:
			id, ok := LDtk_CleanIdentifier(edit.text, style)
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			if id == enumName do return "", {}
			for list in ([]string{"enums", "externalEnums"}) do for d in Json_Items(main, LDtkDoc_Defs(doc, list)) {
				if d != def && Json_String(main, Json_Get(main, d, "identifier")) == id do return fmt.tprintf("another enum is named %s", id), {}
			}
			set(&patches, doc, 0, Json_Get(main, def, "identifier"), Json_Quote(id))
			from, to := fmt.tprintf("LocalEnum.%s", enumName), fmt.tprintf("LocalEnum.%s", id)
			retype :: proc(text, from, to: string) -> (string, bool) {
				if text == from do return to, true
				if text == fmt.tprintf("Array<%s>", from) do return fmt.tprintf("Array<%s>", to), true
				return "", false
			}
			for f in ldtkAllFieldDefs(doc) do if t, ok := retype(Json_String(main, Json_Get(main, f, "__type")), from, to); ok {
				set(&patches, doc, 0, Json_Get(main, f, "__type"), Json_Quote(t))
			}
			for u in ldtkAllFieldInstances(doc) {
				json := LDtkDoc_Json(doc, u.file)
				if t, ok := retype(Json_String(json, Json_Get(json, u.node, "__type")), from, to); ok do set(&patches, doc, u.file, Json_Get(json, u.node, "__type"), Json_Quote(t))
			}
		case .Enum_Value_Name:
			value := Json_At(main, values, edit.index)
			if value < 0 do return "no such value", {}
			old := Json_String(main, Json_Get(main, value, "id"))
			id, ok := LDtk_CleanIdentifier(edit.text, style)
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			if id == old do return "", {}
			for v in Json_Items(main, values) do if v != value && Json_String(main, Json_Get(main, v, "id")) == id do return fmt.tprintf("%s already has a value %s", enumName, id), {}
			set(&patches, doc, 0, Json_Get(main, value, "id"), Json_Quote(id))
			ldtkRenameEnumValue(&patches, doc, edit.def, old, id)
			refresh.toc = true
		case .Enum_Value_Color:
			value := Json_At(main, values, edit.index)
			if value < 0 do return "no such value", {}
			color, ok := LDtk_ParseColor(edit.text)
			if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text), {}
			set(&patches, doc, 0, Json_Get(main, value, "color"), fmt.tprint(color))
		case .Enum_Value_Added:
			id, ok := LDtk_CleanIdentifier(edit.text, style)
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
			for v in Json_Items(main, values) do if Json_String(main, Json_Get(main, v, "id")) == id do return fmt.tprintf("%s already has a value %s", enumName, id), {}
			colors := make([dynamic]int, context.temp_allocator)
			for v in Json_Items(main, values) do append(&colors, Json_Int(main, Json_Get(main, v, "color")))
			item := Json_Object(minified, {"id", Json_Quote(id)}, {"tileRect", "null"}, {"color", fmt.tprint(LDtk_SuggestColor(colors[:]))})
			LDtkPatches_Add(&patches, 0, Json_AppendPatch(main, values, item))
		}
	case .Enum_Added:
		id, ok := LDtk_CleanIdentifier(edit.text, style)
		if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text), {}
		for list in ([]string{"enums", "externalEnums"}) do for d in Json_Items(main, LDtkDoc_Defs(doc, list)) {
			if Json_String(main, Json_Get(main, d, "identifier")) == id do return fmt.tprintf("another enum is named %s", id), {}
		}
		nextUid := Json_Get(main, rootNode, "nextUid")
		uid := Json_Int(main, nextUid)
		item := Json_Object(minified, {"identifier", Json_Quote(id)}, {"uid", fmt.tprint(uid)}, {"values", "[]"}, {"iconTilesetUid", "null"},
			{"externalRelPath", "null"}, {"externalFileChecksum", "null"}, {"tags", "[]"})
		LDtkPatches_Add(&patches, 0, Json_AppendPatch(main, LDtkDoc_Defs(doc, "enums"), item))
		set(&patches, doc, 0, nextUid, fmt.tprint(uid + 1))

	// Worlds
	case .World_Layout, .World_Grid_Width, .World_Grid_Height:
		if edit.world < 0 || edit.world >= len(doc.worlds) do return "no such world", {}
		object := doc.worlds[edit.world].object
		oldLayout := LDtkDoc_WorldLayout(doc, edit.world)
		grid := LDtkDoc_WorldGrid(doc, edit.world)
		newGrid := grid
		layout := oldLayout
		#partial switch edit.op {
		case .World_Layout:
			switch edit.text {
			case "Free", "GridVania", "LinearHorizontal", "LinearVertical": layout = edit.text
			case: return fmt.tprintf("%q isn't a world layout", edit.text), {}
			}
			if layout == oldLayout do return "", {}
			set(&patches, doc, 0, Json_Get(main, object, "worldLayout"), Json_Quote(layout))
		case .World_Grid_Width: newGrid.x = clamp(int(math.round(edit.number)), 1, 100000)
		case .World_Grid_Height: newGrid.y = clamp(int(math.round(edit.number)), 1, 100000)
		}
		if newGrid != grid {
			set(&patches, doc, 0, Json_Get(main, object, "worldGridWidth"), fmt.tprint(newGrid.x))
			set(&patches, doc, 0, Json_Get(main, object, "worldGridHeight"), fmt.tprint(newGrid.y))
		}
		// Where the levels go (LDtk's World.onWorldLayoutChange, onWorldGridChange, reorganizeWorld)
		pos := 0
		for _, level in doc.levels {
			if doc.levels[level].world != edit.world do continue
			rect := LDtkDoc_LevelRect(doc, level)
			x, y := int(rect[0]), int(rect[1])
			switch {
			case layout == "LinearHorizontal" || layout == "LinearVertical":
				// Not stored: placed by their order
				x, y = -1, -1
			case layout == "GridVania" && oldLayout == "Free":
				x, y = (x / newGrid.x) * newGrid.x, (y / newGrid.y) * newGrid.y
			case layout == "GridVania" && oldLayout == "LinearHorizontal":
				x, y = pos * newGrid.x, 0
				pos += int(math.ceil(rect[2] / f64(newGrid.x)))
			case layout == "GridVania" && oldLayout == "LinearVertical":
				x, y = 0, pos * newGrid.y
				pos += int(math.ceil(rect[3] / f64(newGrid.y)))
			case layout == "GridVania" && newGrid != grid:
				x, y = (x / grid.x) * newGrid.x, (y / grid.y) * newGrid.y
			}
			for place in LDtkDoc_LevelObjects(doc, level) {
				json := LDtkDoc_Json(doc, place.file)
				set(&patches, doc, place.file, Json_Get(json, place.node, "worldX"), fmt.tprint(x))
				set(&patches, doc, place.file, Json_Get(json, place.node, "worldY"), fmt.tprint(y))
			}
		}
		refresh = {neighbours = true, worldPositions = true, toc = true}
	}
	if LDtkPatches_Empty(&patches) do return "", rename
	return ldtkCommit(doc, &patches, refresh), rename
}

/*
Whether a project file is too old for the tab's edits (before LDtk 1.0: keys and value forms
changed). LDtk updates a file when it saves it.

Returns:
- "" or why not
*/
LDtkOps_TooOld :: proc(doc: ^LDtkDoc) -> string {
	main := LDtkDoc_Main(doc)
	version := Json_String(main, Json_Get(main, Json_Root(main), "jsonVersion"))
	major, _, _ := strings.partition(version, ".")
	if n, ok := strconv.parse_int(major); ok && n >= 1 do return ""
	return fmt.tprintf("this file is from LDtk %s: open and save it in LDtk 1.x once to edit it here", version == "" ? "before 1.0" : version)
}

/*
Why a layer's grid size can't change ("" when it can): cells drawn in it (IntGrid values, tiles,
auto-layer tiles) would move, and an auto-layer and its source share one grid.
*/
LDtkOps_GridSizeLocked :: proc(doc: ^LDtkDoc, layerUid: int) -> string {
	main := LDtkDoc_Main(doc)
	def := LDtkDoc_DefByUid(doc, "layers", layerUid)
	if def < 0 do return "no such layer"
	if Json_Kind(main, Json_Get(main, def, "autoSourceLayerDefUid")) == .Number do return "an auto-layer takes its source layer's grid"
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if Json_Int(main, Json_Get(main, d, "autoSourceLayerDefUid"), -1) == layerUid do return "an auto-layer uses this layer's cells"
	for li in ldtkLayerInstancesOf(doc, layerUid) {
		json := LDtkDoc_Json(doc, li.file)
		if Json_Count(json, Json_Get(json, li.node, "gridTiles")) > 0 || Json_Count(json, Json_Get(json, li.node, "autoLayerTiles")) > 0 do return "it has tiles drawn: change it in LDtk, which moves them"
		for v in Json_Items(json, Json_Get(json, li.node, "intGridCsv")) do if Json_Int(json, v) != 0 do return "it has cells painted: change it in LDtk, which moves them"
	}
	return ""
}

// Why a field's values can't be edited here ("" when they can)
LDtkOps_FieldLocked :: proc(info: LDtkFieldInfo) -> string {
	if info.isArray do return "arrays aren't editable here yet (LDtk edits them)"
	#partial switch info.type {
	case .Tile: return "tiles aren't editable here yet (LDtk edits them)"
	case .Unknown: return "this field's type isn't known here"
	case .EntityRef: if info.symmetrical do return "symmetrical references aren't editable here yet (LDtk keeps both ends)"
	}
	return ""
}

// A field definition's kind of value
LDtkFieldType :: enum {
	Unknown,
	Int,
	Float,
	String,
	Text,
	Bool,
	Color,
	Point,
	Enum,
	Path,
	EntityRef,
	Tile,
}

// What a field definition is (strings point into the document)
LDtkFieldInfo :: struct {
	node, uid: int,
	identifier: string,
	type: LDtkFieldType,
	// An enum field's enum uid (-1 otherwise)
	enumUid: int,
	isArray, canBeNull, symmetrical, outOfLevel: bool,
	min, max: Maybe(f64),
	// "Any", "OnlySame", "OnlyTags", "OnlySpecificEntity" (entity references)
	allowedRefs: string,
	// The default as `__value` text
	defaultText: string,
}

// A field definition's description
LDtkDoc_FieldInfo :: proc(doc: ^LDtkDoc, node: int) -> LDtkFieldInfo {
	main := LDtkDoc_Main(doc)
	info := LDtkFieldInfo{node = node, uid = Json_Int(main, Json_Get(main, node, "uid"), -1), enumUid = -1}
	info.identifier = Json_String(main, Json_Get(main, node, "identifier"))
	info.isArray = Json_Bool(main, Json_Get(main, node, "isArray"))
	info.canBeNull = Json_Bool(main, Json_Get(main, node, "canBeNull"))
	info.symmetrical = Json_Bool(main, Json_Get(main, node, "symmetricalRef"))
	info.outOfLevel = Json_Bool(main, Json_Get(main, node, "allowOutOfLevelRef"), true)
	info.allowedRefs = Json_String(main, Json_Get(main, node, "allowedRefs"))
	if v, ok := Json_Number(main, Json_Get(main, node, "min")); ok do info.min = v
	if v, ok := Json_Number(main, Json_Get(main, node, "max")); ok do info.max = v
	t := Json_String(main, Json_Get(main, node, "type"))
	switch {
	case t == "F_Int":       info.type = .Int
	case t == "F_Float":     info.type = .Float
	case t == "F_String":    info.type = .String
	case t == "F_Text":      info.type = .Text
	case t == "F_Bool":      info.type = .Bool
	case t == "F_Color":     info.type = .Color
	case t == "F_Point":     info.type = .Point
	case t == "F_Path":      info.type = .Path
	case t == "F_EntityRef": info.type = .EntityRef
	case t == "F_Tile":      info.type = .Tile
	case strings.has_prefix(t, "F_Enum("):
		info.type = .Enum
		if uid, ok := strconv.parse_int(strings.trim_suffix(t[len("F_Enum("):], ")")); ok do info.enumUid = uid
	}
	info.defaultText = ldtkDefaultText(info, Json_Text(main, Json_Get(main, node, "defaultOverride")))
	return info
}

// A field's default as `__value` text, from its `defaultOverride` text (LDtk's FieldDef.get*Default)
@(private="file")
ldtkDefaultText :: proc(info: LDtkFieldInfo, override: string) -> string {
	if info.isArray do return "[]"
	param := ""
	if override != "" && override != "null" {
		doc, problem := Json_Parse(override, context.temp_allocator)
		if problem == "" do param = strings.clone(Json_Text(&doc, Json_At(&doc, Json_Get(&doc, 0, "params"), 0)), context.temp_allocator)
	}
	if param != "" {
		#partial switch info.type {
		case .Color:
			if v, ok := strconv.parse_int(param); ok do return Json_Quote(LDtk_FormatColor(v))
		case .Point:
			raw := Json_Unquote(param)
			cx, _, cy := strings.partition(raw, ",")
			return fmt.tprintf(`{"cx":%s,"cy":%s}`, strings.trim_space(cx), strings.trim_space(cy))
		case: return param
		}
	}
	if info.canBeNull do return "null"
	#partial switch info.type {
	case .Int, .Float: return "0"
	case .Bool: return "false"
	case .String, .Text, .Path: return `""`
	case .Color: return `"#000000"`
	}
	return "null"
}

// Whether a field instance uses its definition's default (no editor value of its own)
@(private="file")
ldtkUsesDefault :: proc(json: ^JsonDoc, fieldInstance: int) -> bool {
	raw := Json_Get(json, fieldInstance, "realEditorValues")
	for v in Json_Items(json, raw) do if Json_Kind(json, v) != .Null do return false
	return true
}

/*
A field's value from typed text, as `__value` JSON and `realEditorValues` JSON (LDtk's
FieldInstance.parseValue and toJson): clamped to its range, an enum's value checked.

Returns:
- The two texts, and false with why when the text isn't a value of the field's type
*/
@(private="file")
ldtkFieldValue :: proc(doc: ^LDtkDoc, info: LDtkFieldInfo, text: string, minified: bool) -> (value, raw: string, ok: bool, problem: string) {
	wrap :: proc(minified: bool, id, param: string) -> string {
		return Json_Array(Json_Object(minified, {"id", Json_Quote(id)}, {"params", Json_Array(param)}))
	}
	t := strings.trim_space(text)
	#partial switch info.type {
	case .Int:
		v, parsed := strconv.parse_f64(t)
		if !parsed do return "", "", false, fmt.tprintf("%q isn't a whole number", text)
		n := int(math.round(v))
		if lo, has := info.min.?; has do n = max(n, int(math.ceil(lo)))
		if hi, has := info.max.?; has do n = min(n, int(math.floor(hi)))
		return fmt.tprint(n), wrap(minified, "V_Int", fmt.tprint(n)), true, ""
	case .Float:
		v, parsed := strconv.parse_f64(t)
		if !parsed do return "", "", false, fmt.tprintf("%q isn't a number", text)
		if lo, has := info.min.?; has do v = max(v, lo)
		if hi, has := info.max.?; has do v = min(v, hi)
		n := Json_FormatNumber(v, 3)
		return n, wrap(minified, "V_Float", n), true, ""
	case .Bool:
		switch strings.to_lower(t, context.temp_allocator) {
		case "true": return "true", wrap(minified, "V_Bool", "true"), true, ""
		case "false": return "false", wrap(minified, "V_Bool", "false"), true, ""
		}
		return "", "", false, "true or false"
	case .String, .Path:
		// LDtk keeps strings on one line
		line, _ := strings.replace_all(text, "\n", " ", context.temp_allocator)
		q := Json_Quote(line)
		return q, wrap(minified, "V_String", q), true, ""
	case .Text:
		q := Json_Quote(text)
		return q, wrap(minified, "V_String", q), true, ""
	case .Color:
		c, parsed := LDtk_ParseColor(t)
		if !parsed do return "", "", false, fmt.tprintf("%q isn't a color (#RRGGBB)", text)
		return Json_Quote(LDtk_FormatColor(c)), wrap(minified, "V_Int", fmt.tprint(c)), true, ""
	case .Enum:
		if !slice.contains(LDtkDoc_EnumValues(doc, info.enumUid), t) do return "", "", false, fmt.tprintf("%q isn't one of the enum's values", text)
		q := Json_Quote(t)
		return q, wrap(minified, "V_String", q), true, ""
	case .Point:
		xs, _, ys := strings.partition(t, ",")
		x, xok := strconv.parse_int(strings.trim_space(xs))
		y, yok := strconv.parse_int(strings.trim_space(ys))
		if !xok || !yok do return "", "", false, fmt.tprintf("%q isn't a cell (x, y)", text)
		return Json_Object(minified, {"cx", fmt.tprint(x)}, {"cy", fmt.tprint(y)}), wrap(minified, "V_String", Json_Quote(fmt.tprintf("%d,%d", x, y))), true, ""
	}
	return "", "", false, fmt.tprintf("%v fields aren't editable here yet", info.type)
}

// An enum's value names (temp allocated; none for an unknown uid)
LDtkDoc_EnumValues :: proc(doc: ^LDtkDoc, enumUid: int) -> []string {
	main := LDtkDoc_Main(doc)
	out := make([dynamic]string, context.temp_allocator)
	def := LDtkDoc_DefByUid(doc, "enums", enumUid)
	if def < 0 do def = LDtkDoc_DefByUid(doc, "externalEnums", enumUid)
	for v in Json_Items(main, Json_Get(main, def, "values")) do append(&out, Json_String(main, Json_Get(main, v, "id")))
	return out[:]
}

// An entity reference's `__value` (LDtk's EntityReferenceInfos)
@(private="file")
ldtkRefValue :: proc(doc: ^LDtkDoc, target: LDtkDocEntity, minified: bool) -> string {
	json := LDtkDoc_Json(doc, target.file)
	_, levelIid := LDtkDoc_LevelNames(doc, target.level)
	_, worldIid := LDtkDoc_WorldNames(doc, doc.levels[target.level].world)
	return Json_Object(minified,
		{"entityIid", Json_Quote(Json_String(json, Json_Get(json, target.node, "iid")))},
		{"layerIid", Json_Quote(Json_String(json, Json_Get(json, target.layer, "iid")))},
		{"levelIid", Json_Quote(levelIid)},
		{"worldIid", Json_Quote(worldIid)})
}

/*
Whether an entity reference field of `source` may point at `target`, by the field's rules
(LDtk's allowedRefs, allowOutOfLevelRef).
*/
LDtkOps_RefAllowed :: proc(doc: ^LDtkDoc, info: LDtkFieldInfo, source, target: LDtkDocEntity) -> bool {
	if source.node == target.node && source.file == target.file do return false
	if !info.outOfLevel && source.level != target.level do return false
	main := LDtkDoc_Main(doc)
	sjson, tjson := LDtkDoc_Json(doc, source.file), LDtkDoc_Json(doc, target.file)
	targetDef := Json_Int(tjson, Json_Get(tjson, target.node, "defUid"), -1)
	switch info.allowedRefs {
	case "OnlySame":
		return targetDef == Json_Int(sjson, Json_Get(sjson, source.node, "defUid"), -2)
	case "OnlySpecificEntity":
		return targetDef == Json_Int(main, Json_Get(main, info.node, "allowedRefsEntityUid"), -2)
	case "OnlyTags":
		allowed := Json_Get(main, info.node, "allowedRefTags")
		for tag in Json_Items(tjson, Json_Get(tjson, target.node, "__tags")) {
			for a in Json_Items(main, allowed) do if Json_String(main, a) == Json_String(tjson, tag) do return true
		}
		return false
	}
	return true
}

// A layer instance of some level
@(private="file")
LDtkLayerPlace :: struct {
	level, file, node: int,
}

// Every level's instance of a layer definition (temp allocated)
@(private="file")
ldtkLayerInstancesOf :: proc(doc: ^LDtkDoc, layerUid: int) -> []LDtkLayerPlace {
	out := make([dynamic]LDtkLayerPlace, context.temp_allocator)
	for _, level in doc.levels {
		file, array := LDtkDoc_LayerInstances(doc, level)
		json := LDtkDoc_Json(doc, file)
		for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == layerUid do append(&out, LDtkLayerPlace{level, file, li})
	}
	return out[:]
}

// Every instance of an entity definition (temp allocated)
@(private="file")
ldtkEntitiesOf :: proc(doc: ^LDtkDoc, defUid: int) -> []LDtkDocEntity {
	out := make([dynamic]LDtkDocEntity, context.temp_allocator)
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		if Json_Int(json, Json_Get(json, e.node, "defUid"), -1) == defUid do append(&out, e)
	}
	return out[:]
}

// A field definition by uid: its owner (an entity definition, or the levelFields list) and itself
// (-1 when there's none)
LDtkDoc_FieldDef :: proc(doc: ^LDtkDoc, uid: int) -> (owner, def: int) {
	main := LDtkDoc_Main(doc)
	for f in Json_Items(main, LDtkDoc_Defs(doc, "levelFields")) do if Json_Int(main, Json_Get(main, f, "uid"), -1) == uid do return LDtkDoc_Defs(doc, "levelFields"), f
	for e in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
		for f in Json_Items(main, Json_Get(main, e, "fieldDefs")) do if Json_Int(main, Json_Get(main, f, "uid"), -1) == uid do return e, f
	}
	return -1, -1
}

// Every field definition (entities' and levels'; temp allocated)
@(private="file")
ldtkAllFieldDefs :: proc(doc: ^LDtkDoc) -> []int {
	main := LDtkDoc_Main(doc)
	out := make([dynamic]int, context.temp_allocator)
	for e in Json_Items(main, LDtkDoc_Defs(doc, "entities")) do append(&out, ..Json_Items(main, Json_Get(main, e, "fieldDefs")))
	append(&out, ..Json_Items(main, LDtkDoc_Defs(doc, "levelFields")))
	return out[:]
}

// Every field instance (entities' and levels', each copy of a level's; temp allocated)
@(private="file")
ldtkAllFieldInstances :: proc(doc: ^LDtkDoc) -> []LDtkDocPlace {
	out := make([dynamic]LDtkDocPlace, context.temp_allocator)
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) do append(&out, LDtkDocPlace{e.file, fi})
	}
	for _, level in doc.levels do for place in LDtkDoc_LevelObjects(doc, level) {
		json := LDtkDoc_Json(doc, place.file)
		for fi in Json_Items(json, Json_Get(json, place.node, "fieldInstances")) do append(&out, LDtkDocPlace{place.file, fi})
	}
	return out[:]
}

// Every instance of a field definition (temp allocated)
@(private="file")
ldtkFieldInstancesOf :: proc(doc: ^LDtkDoc, fieldUid: int) -> []LDtkDocPlace {
	out := make([dynamic]LDtkDocPlace, context.temp_allocator)
	for fi in ldtkAllFieldInstances(doc) {
		json := LDtkDoc_Json(doc, fi.file)
		if Json_Int(json, Json_Get(json, fi.node, "defUid"), -1) == fieldUid do append(&out, fi)
	}
	return out[:]
}

// Renames an enum's value wherever it's used: field values and their editor values, fields'
// defaults, tilesets' enum tags (LDtk's EnumDef.renameValue)
@(private="file")
ldtkRenameEnumValue :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc, enumUid: int, from, to: string) {
	main := LDtkDoc_Main(doc)
	fromQ, toQ := Json_Quote(from), Json_Quote(to)
	// Strings equal to the old value inside a node (a value, an array of them, editor values)
	rename :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc, file, node: int, fromQ, toQ: string) {
		json := LDtkDoc_Json(doc, file)
		switch Json_Kind(json, node) {
		case .String:
			if Json_Text(json, node) == fromQ do LDtkPatches_Set(patches, doc, file, node, toQ)
		case .Array, .Object:
			for c in Json_Items(json, node) do rename(patches, doc, file, c, fromQ, toQ)
		case .Null, .False, .True, .Number:
		}
	}
	fields := make(map[int]bool, context.temp_allocator)
	for f in ldtkAllFieldDefs(doc) {
		info := LDtkDoc_FieldInfo(doc, f)
		if info.type != .Enum || info.enumUid != enumUid do continue
		fields[info.uid] = true
		rename(patches, doc, 0, Json_Get(main, Json_Get(main, f, "defaultOverride"), "params"), fromQ, toQ)
	}
	for fi in ldtkAllFieldInstances(doc) {
		json := LDtkDoc_Json(doc, fi.file)
		if Json_Int(json, Json_Get(json, fi.node, "defUid"), -1) not_in fields do continue
		rename(patches, doc, fi.file, Json_Get(json, fi.node, "__value"), fromQ, toQ)
		for raw in Json_Items(json, Json_Get(json, fi.node, "realEditorValues")) do rename(patches, doc, fi.file, Json_Get(json, raw, "params"), fromQ, toQ)
	}
	for t in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) {
		if Json_Int(main, Json_Get(main, t, "tagsSourceEnumUid"), -1) != enumUid do continue
		for tag in Json_Items(main, Json_Get(main, t, "enumTags")) do rename(patches, doc, 0, Json_Get(main, tag, "enumValueId"), fromQ, toQ)
	}
}

// Swaps two nodes' texts (array items of one array: layers reordered)
@(private="file")
ldtkSwap :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc, file, a, b: int) {
	json := LDtkDoc_Json(doc, file)
	ta, tb := strings.clone(Json_Text(json, a), context.temp_allocator), strings.clone(Json_Text(json, b), context.temp_allocator)
	LDtkPatches_Add(patches, file, Json_SetPatch(json, a, tb))
	LDtkPatches_Add(patches, file, Json_SetPatch(json, b, ta))
}

// Moves an array item from `from` to `to` (the items between shift by one): each item in the range
// takes the text of the one that ends up there (array items of one array: layers reordered)
@(private="file")
ldtkMove :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc, file: int, items: []int, from, to: int) {
	json := LDtkDoc_Json(doc, file)
	texts := make([]string, len(items), context.temp_allocator)
	for item, i in items do texts[i] = strings.clone(Json_Text(json, item), context.temp_allocator)
	order := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< len(items) do if i != from do append(&order, i)
	inject_at(&order, to, from)
	for i in min(from, to) ..= max(from, to) do LDtkPatches_Add(patches, file, Json_SetPatch(json, items[i], texts[order[i]]))
}

// The grid size of the layer an entity is in
@(private="file")
ldtkInstanceGrid :: proc(doc: ^LDtkDoc, e: LDtkDocEntity) -> int {
	json := LDtkDoc_Json(doc, e.file)
	return max(Json_Int(json, Json_Get(json, e.layer, "__gridSize"), 16), 1)
}

// An entity's `__grid` for a new grid size (its pivot as its definition has it)
@(private="file")
ldtkSetGrid :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc, file, entity, grid: int) {
	main := LDtkDoc_Main(doc)
	json := LDtkDoc_Json(doc, file)
	def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, entity, "defUid"), -1))
	ldtkSetGridPivot(patches, doc, file, entity, grid, Json_Float(main, Json_Get(main, def, "pivotX")), Json_Float(main, Json_Get(main, def, "pivotY")))
}

// An entity's `__grid` from its position (`px`, or the one given), its pivot and grid
// (LDtk's EntityInstance.getCx: a pivot of 1 counts the pixel before it)
@(private="file")
ldtkSetGridPivot :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc, file, entity, grid: int, pivotX, pivotY: f64, at: Maybe([2]int) = nil) {
	json := LDtkDoc_Json(doc, file)
	px := Json_Get(json, entity, "px")
	pos := at.? or_else [2]int{Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))}
	cx := (pos.x + (pivotX == 1 ? -1 : 0)) / max(grid, 1)
	cy := (pos.y + (pivotY == 1 ? -1 : 0)) / max(grid, 1)
	LDtkPatches_Set(patches, doc, file, Json_Get(json, entity, "__grid"), Json_Array(fmt.tprint(cx), fmt.tprint(cy)))
}

/*
Makes an edit in the document (in memory: saving writes it): its patches, then (from what they
make) what LDtk keeps in step: neighbours, entities' world positions, the table of contents.
*/
@(private="file")
ldtkCommit :: proc(doc: ^LDtkDoc, patches: ^LDtkPatches, refresh: LDtkRefresh) -> string {
	texts := LDtkDoc_Texts(doc)
	if problem := LDtkDoc_Apply(doc, texts, patches); problem != "" do return problem
	if refresh != {} {
		after := LDtkDoc_FromTexts(doc, texts)
		defer LDtkDoc_Free(&after)
		if after.problem == "" {
			more := LDtkPatches{}
			if refresh.neighbours do refreshNeighbours(&more, &after)
			if refresh.worldPositions do refreshWorldPositions(&more, &after)
			if refresh.toc do refreshToc(&more, &after)
			// The second pass's spans are the first pass's results'
			second := LDtkDoc_Texts(&after)
			if problem := LDtkDoc_Apply(&after, second, &more); problem != "" do return problem
			for t, i in second do texts[i] = strings.clone(t, context.temp_allocator)
		}
	}
	return LDtkDoc_SetTexts(doc, texts)
}

// A level's neighbour as LDtk lists it
LDtkNeighbour :: struct {
	iid: string,
	// "o" overlapping, "<" / ">" a depth below / above, "n" "s" "e" "w" "ne" "nw" "se" "sw" touching
	dir: string,
}

/*
A level's neighbours by LDtk's rule (Level.getNeighboursJson): levels overlapping it within one
depth, then levels of its depth touching it (sides, then corners); none in linear layouts.

Returns:
- The neighbours, in the world's level order (temp allocated)
*/
LDtkDoc_Neighbours :: proc(doc: ^LDtkDoc, level: int) -> []LDtkNeighbour {
	out := make([dynamic]LDtkNeighbour, context.temp_allocator)
	world := doc.levels[level].world
	layout := LDtkDoc_WorldLayout(doc, world)
	if layout != "Free" && layout != "GridVania" do return out[:]
	main := LDtkDoc_Main(doc)
	depth :: proc(doc: ^LDtkDoc, level: int) -> int {
		main := LDtkDoc_Main(doc)
		return Json_Int(main, Json_Get(main, doc.levels[level].entry, "worldDepth"))
	}
	overlaps :: proc(a, b: [4]f64) -> bool {
		return b[0] < a[0] + a[2] && b[0] + b[2] > a[0] && b[1] < a[1] + a[3] && b[1] + b[3] > a[1]
	}
	r := LDtkDoc_LevelRect(doc, level)
	d := depth(doc, level)
	for o, i in doc.levels {
		if i == level || o.world != world do continue
		or := LDtkDoc_LevelRect(doc, i)
		od := depth(doc, i)
		if abs(d - od) <= 1 && overlaps(r, or) {
			_, iid := LDtkDoc_LevelNames(doc, i)
			append(&out, LDtkNeighbour{iid, od == d ? "o" : (od > d ? ">" : "<")})
		}
	}
	for o, i in doc.levels {
		if i == level || o.world != world do continue
		or := LDtkDoc_LevelRect(doc, i)
		if depth(doc, i) != d || overlaps(r, or) do continue
		dist := max(max(0, r[0] - (or[0] + or[2])) + max(0, or[0] - (r[0] + r[2])), max(0, r[1] - (or[1] + or[3])) + max(0, or[1] - (r[1] + r[3])))
		if dist != 0 do continue
		x, y, w, h := r[0], r[1], r[2], r[3]
		dir := ""
		switch {
		case or[0] == x + w && or[1] == y + h:           dir = "se"
		case or[0] + or[2] == x && or[1] == y + h:       dir = "sw"
		case or[0] == x + w && or[1] + or[3] == y:       dir = "ne"
		case or[0] + or[2] == x && or[1] + or[3] == y:   dir = "nw"
		case or[0] >= x + w:                             dir = "e"
		case or[0] + or[2] <= x:                         dir = "w"
		case or[1] + or[3] <= y:                         dir = "n"
		case:                                            dir = "s"
		}
		_, iid := LDtkDoc_LevelNames(doc, i)
		append(&out, LDtkNeighbour{iid, dir})
	}
	_ = main
	return out[:]
}

// Every level's `__neighbours`, where they differ from LDtk's rule (an equal set is left as written)
@(private="file")
refreshNeighbours :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc) {
	for _, level in doc.levels {
		wanted := LDtkDoc_Neighbours(doc, level)
		for place in LDtkDoc_LevelObjects(doc, level) {
			json := LDtkDoc_Json(doc, place.file)
			array := Json_Get(json, place.node, "__neighbours")
			if array < 0 do continue
			same := Json_Count(json, array) == len(wanted)
			if same do for n in wanted {
				found := false
				for item in Json_Items(json, array) {
					if Json_String(json, Json_Get(json, item, "levelIid")) == n.iid && Json_String(json, Json_Get(json, item, "dir")) == n.dir do found = true
				}
				if !found do same = false
			}
			if same do continue
			minified := Json_Minified(json)
			items := make([dynamic]string, context.temp_allocator)
			for n in wanted do append(&items, Json_Object(minified, {"levelIid", Json_Quote(n.iid)}, {"dir", Json_Quote(n.dir)}))
			LDtkPatches_Set(patches, doc, place.file, array, Json_Array(..items[:]))
		}
	}
}

// Entities' `__worldX` / `__worldY` (where the file has them) from their level's place
@(private="file")
refreshWorldPositions :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc) {
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		rect := LDtkDoc_LevelRect(doc, e.level)
		px := Json_Get(json, e.node, "px")
		x := int(rect[0]) + Json_Int(json, Json_At(json, px, 0))
		y := int(rect[1]) + Json_Int(json, Json_At(json, px, 1))
		wx, wy := Json_Get(json, e.node, "__worldX"), Json_Get(json, e.node, "__worldY")
		if Json_Kind(json, wx) == .Number do LDtkPatches_Set(patches, doc, e.file, wx, fmt.tprint(x))
		if Json_Kind(json, wy) == .Number do LDtkPatches_Set(patches, doc, e.file, wy, fmt.tprint(y))
	}
}

// The table of contents' entries from the entities they list: world position, size, exported
// fields' values
@(private="file")
refreshToc :: proc(patches: ^LDtkPatches, doc: ^LDtkDoc) {
	main := LDtkDoc_Main(doc)
	toc := Json_Get(main, Json_Root(main), "toc")
	if Json_Count(main, toc) == 0 do return
	entities := make(map[string]LDtkDocEntity, context.temp_allocator)
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		entities[Json_String(json, Json_Get(json, e.node, "iid"))] = e
	}
	for entry in Json_Items(main, toc) do for data in Json_Items(main, Json_Get(main, entry, "instancesData")) {
		e, found := entities[Json_String(main, Json_Get(main, Json_Get(main, data, "iids"), "entityIid"))]
		if !found do continue
		json := LDtkDoc_Json(doc, e.file)
		rect := LDtkDoc_LevelRect(doc, e.level)
		px := Json_Get(json, e.node, "px")
		LDtkPatches_Set(patches, doc, 0, Json_Get(main, data, "worldX"), fmt.tprint(int(rect[0]) + Json_Int(json, Json_At(json, px, 0))))
		LDtkPatches_Set(patches, doc, 0, Json_Get(main, data, "worldY"), fmt.tprint(int(rect[1]) + Json_Int(json, Json_At(json, px, 1))))
		LDtkPatches_Set(patches, doc, 0, Json_Get(main, data, "widPx"), Json_Text(json, Json_Get(json, e.node, "width")))
		LDtkPatches_Set(patches, doc, 0, Json_Get(main, data, "heiPx"), Json_Text(json, Json_Get(json, e.node, "height")))
		fields := Json_Get(main, data, "fields")
		for member in Json_Items(main, fields) {
			key := Json_Key(main, member)
			for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
				if Json_String(json, Json_Get(json, fi, "__identifier")) != key do continue
				value := Json_Get(json, fi, "__value")
				if !jsonSameValue(main, member, json, value) do LDtkPatches_Set(patches, doc, 0, member, Json_Text(json, value))
			}
		}
	}
}

// Whether two values are the same JSON (whatever their spacing)
@(private="file")
jsonSameValue :: proc(a: ^JsonDoc, an: int, b: ^JsonDoc, bn: int) -> bool {
	ka, kb := Json_Kind(a, an), Json_Kind(b, bn)
	if ka != kb do return false
	switch ka {
	case .Null, .True, .False: return true
	case .Number:
		x, _ := Json_Number(a, an)
		y, _ := Json_Number(b, bn)
		return x == y
	case .String: return Json_String(a, an) == Json_String(b, bn)
	case .Array:
		ia, ib := Json_Items(a, an), Json_Items(b, bn)
		if len(ia) != len(ib) do return false
		for x, i in ia do if !jsonSameValue(a, x, b, ib[i]) do return false
		return true
	case .Object:
		if Json_Count(a, an) != Json_Count(b, bn) do return false
		for x in Json_Items(a, an) {
			y := Json_Get(b, bn, Json_Key(a, x))
			if y < 0 || !jsonSameValue(a, x, b, y) do return false
		}
		return true
	}
	return false
}

/*
An identifier cleaned up as LDtk does (Project.cleanupIdentifier): trimmed, runs of other
characters made "_", leading digits "_", repeated "_" one, then the project's style
("Capitalize", "Uppercase", "Lowercase", "Free").

Returns:
- The identifier (temp allocated), and false when nothing usable is left
*/
LDtk_CleanIdentifier :: proc(id: string, style: string) -> (string, bool) {
	t := strings.trim_space(id)
	if t == "" do return "", false
	b := strings.builder_make(context.temp_allocator)
	last := byte(0)
	for i in 0 ..< len(t) {
		c := t[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		out := ok ? c : '_'
		// Runs of "_" become one
		if out == '_' && last == '_' do continue
		strings.write_byte(&b, out)
		last = out
	}
	s := strings.to_string(b)
	// Leading digits become "_"
	if len(s) > 0 && s[0] >= '0' && s[0] <= '9' {
		i := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
		s = fmt.tprintf("_%s", s[i:])
		s, _ = strings.replace_all(s, "__", "_", context.temp_allocator)
	}
	if s == "" do return "", false
	switch style {
	case "Capitalize":
		i := 0
		for i < len(s) && s[i] == '_' do i += 1
		if i < len(s) && s[i] >= 'a' && s[i] <= 'z' do s = fmt.tprintf("%s%c%s", s[:i], s[i] - 32, s[i + 1:])
	case "Uppercase": s = strings.to_upper(s, context.temp_allocator)
	case "Lowercase": s = strings.to_lower(s, context.temp_allocator)
	}
	return s, true
}

// A color from "#RRGGBB" (or "RRGGBB") as LDtk's int (0xRRGGBB)
LDtk_ParseColor :: proc(text: string) -> (int, bool) {
	t := strings.trim_prefix(strings.trim_space(text), "#")
	if len(t) != 6 do return 0, false
	v, ok := strconv.parse_int(t, 16)
	return v, ok && v >= 0
}

// LDtk's color text for an int (#RRGGBB, upper case)
LDtk_FormatColor :: proc(color: int) -> string {
	return fmt.tprintf("#%06X", color & 0xFFFFFF)
}

// A coordinate on a world grid (LDtk's snapWorldGridX: the nearest line)
LDtk_SnapToGrid :: proc(v, grid: int) -> int {
	g := max(grid, 1)
	return int(math.round(f64(v) / f64(g))) * g
}

// A color for a new enum value, apart from the ones it has (LDtk's Const.suggestNiceColor)
LDtk_SuggestColor :: proc(taken: []int) -> int {
	palette := [?]int{0xBE4A2F, 0xD77643, 0xEAD4AA, 0xE4A672, 0xB86F50, 0x733E39, 0x3E2731, 0xA22633, 0xE43B44, 0xF77622,
		0xFEAE34, 0xFEE761, 0x63C74D, 0x3E8948, 0x265C42, 0x193C3E, 0x124E89, 0x0099DB, 0x2CE8F5, 0xC0CBDC}
	for c in palette do if !slice.contains(taken, c) do return c
	return palette[len(taken) % len(palette)]
}
