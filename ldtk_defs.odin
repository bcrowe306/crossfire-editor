package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
The definitions editors' edits (the Level mode's Layers, Entities, Enums, Tilesets and Level tabs:
view_ldtk_defs.odin), as LDtk's definition panels make them (its EditLayerDefs, EditEntityDefs,
FieldDefsForm, EditEnumDefs, EditTilesetDefs, EditLevelFieldDefs, data/Definitions.hx and the
definitions' classes in data/def/, misc/FieldTypeConverter.hx, importer/ExternalEnum.hx).

**How an edit is made.** The definition changes first (a member written, a definition added,
copied, removed or moved: `LDtk_Edit.op` `Def_*`, IntGrid values and groups, enum values,
tilesets' tiles); then what LDtk does beside it in its panel's handler (a grid change remaps every
level's cells, a Tiles layer takes its tileset's grid, auto-layers' rules are applied again where
their tiles depend on what changed); then LDtk's tidy brings every level's instances in step with
the definitions (ldtk_tidy.odin: layer instances added and removed, fields added at their default,
values converted, lost references and values cleared, every derived value). All of it is one
document change, one undo step, in memory until Save.

**Members** (`LDTK_MEMBERS`): what each definition list has, the kind of value each member takes
(`LDtkMemberKind`) and its bounds, LDtk's inputs' (`Input.setBounds`, `fixValue`). `Def_Set` writes
one, then its handler's consequences (`defConsequences`): a layer's parallax Y following X while
they were equal, a resizable entity's minimum taking its size, references limited to tags turning
symmetry off, a range swapped when reversed and the default clamped into it, and so on.

**New definitions** are written in LDtk's key order with LDtk's defaults (LayerDef, EntityDef,
FieldDef, EnumDef, TilesetDef's `toJson` of a new one), uids from `nextUid`, identifiers made
unique as LDtk makes them (`ldtkUniqueId`: "Entity", "Entity2"...; a name ending in a number counts
on from it).
*/

// The kind of value a definition's member takes
LDtkMemberKind :: enum u8 {
	// `flag`
	Bool,
	// `number` (or `text` when typed), rounded and clamped to the member's bounds
	Int,
	Float,
	// `text`: "" is null
	Nullable_Int,
	Nullable_Float,
	// `text`, trimmed; empty is null (LDtk's escapeNullableString)
	Nullable_String,
	// `text` as typed (not trimmed); empty is null
	Raw_String,
	// `text`: "#RRGGBB"
	Color,
	Nullable_Color,
	// `text`: one of the member's choices
	Choice,
	Nullable_Choice,
	// `text`: a definition's uid, "" (or -1) null
	Uid,
	// `text`: names separated by commas or spaces (LDtk's Tags: cleaned up, unique, in order)
	Tags,
	// `text` "x,y,w,h" of the tileset `number`, "" null
	Rect,
	// Handled by its own code (`defSpecial`)
	Special,
}

// A definition's member the editors set (`Def_Set`)
LDtkMember :: struct {
	kind: LDtkDefKind,
	key: string,
	type: LDtkMemberKind,
	lo, hi: f64,
	choices: []string,
	// What the undo step says ("a layer's grid size")
	label: string,
}

// LDtk's choices (its ldtk.Json enums)
LDTK_LAYER_TYPES :: []string{"IntGrid", "Entities", "Tiles", "AutoLayer"}
LDTK_RENDER_MODES :: []string{"Rectangle", "Ellipse", "Cross", "Tile"}
LDTK_TILE_RENDER_MODES :: []string{"Cover", "FitInside", "Repeat", "Stretch", "FullSizeCropped", "FullSizeUncropped", "NineSlice"}
LDTK_LIMIT_SCOPES :: []string{"PerLayer", "PerLevel", "PerWorld"}
LDTK_LIMIT_BEHAVIORS :: []string{"DiscardOldOnes", "PreventAdding", "MoveLastOne"}
LDTK_DISPLAY_MODES :: []string{"Hidden", "ValueOnly", "NameAndValue", "EntityTile", "LevelTile", "Points", "PointStar", "PointPath",
	"PointPathLoop", "RadiusPx", "RadiusGrid", "ArrayCountWithLabel", "ArrayCountNoLabel", "RefLinkBetweenPivots", "RefLinkBetweenCenters"}
LDTK_DISPLAY_POSITIONS :: []string{"Above", "Center", "Beneath"}
LDTK_LINK_STYLES :: []string{"ZigZag", "StraightArrow", "CurvedArrow", "ArrowsLine", "DashedLine"}
LDTK_ALLOWED_REFS :: []string{"Any", "OnlySame", "OnlyTags", "OnlySpecificEntity"}
LDTK_TEXT_LANGUAGES :: []string{"LangPython", "LangRuby", "LangJS", "LangLua", "LangC", "LangHaxe", "LangMarkdown", "LangJson", "LangXml", "LangLog"}
// Const.MAX_GRID_SIZE
LDTK_MAX_GRID_SIZE :: 1024

// Every member the editors set, by definition list (LDtk's panels' inputs and their bounds)
LDTK_MEMBERS := [?]LDtkMember{
	// Layers (EditLayerDefs)
	{.Layer, "doc", .Nullable_String, 0, 0, nil, "a layer's documentation"},
	{.Layer, "uiColor", .Nullable_Color, 0, 0, nil, "a layer's color"},
	{.Layer, "gridSize", .Special, 1, LDTK_MAX_GRID_SIZE, nil, "a layer's grid size"},
	{.Layer, "guideGridWid", .Int, 0, LDTK_MAX_GRID_SIZE, nil, "a layer's guide grid"},
	{.Layer, "guideGridHei", .Int, 0, LDTK_MAX_GRID_SIZE, nil, "a layer's guide grid"},
	{.Layer, "displayOpacity", .Float, 0.1, 1, nil, "a layer's opacity"},
	{.Layer, "inactiveOpacity", .Float, 0, 1, nil, "a layer's opacity when inactive"},
	{.Layer, "hideInList", .Bool, 0, 0, nil, "whether a layer is in the list"},
	{.Layer, "hideFieldsWhenInactive", .Bool, 0, 0, nil, "whether a layer hides its fields"},
	{.Layer, "canSelectWhenInactive", .Bool, 0, 0, nil, "whether a layer is picked when inactive"},
	{.Layer, "renderInWorldView", .Bool, 0, 0, nil, "whether the world view shows a layer"},
	{.Layer, "useAsyncRender", .Bool, 0, 0, nil, "a layer's rendering"},
	{.Layer, "pxOffsetX", .Int, -100000, 100000, nil, "a layer's offset"},
	{.Layer, "pxOffsetY", .Int, -100000, 100000, nil, "a layer's offset"},
	{.Layer, "parallaxFactorX", .Float, -1, 1, nil, "a layer's parallax"},
	{.Layer, "parallaxFactorY", .Float, -1, 1, nil, "a layer's parallax"},
	{.Layer, "parallaxScaling", .Bool, 0, 0, nil, "a layer's parallax scaling"},
	{.Layer, "uiFilterTags", .Tags, 0, 0, nil, "a layer's filter tags"},
	{.Layer, "requiredTags", .Tags, 0, 0, nil, "a layer's required tags"},
	{.Layer, "excludedTags", .Tags, 0, 0, nil, "a layer's excluded tags"},
	{.Layer, "tilesetDefUid", .Uid, 0, 0, nil, "a layer's tileset"},
	{.Layer, "autoSourceLayerDefUid", .Uid, 0, 0, nil, "an auto-layer's source"},
	{.Layer, "autoTilesKilledByOtherLayerUid", .Uid, 0, 0, nil, "the layer removing an auto-layer's tiles"},
	{.Layer, "biomeFieldUid", .Uid, 0, 0, nil, "an auto-layer's biome field"},
	{.Layer, "tilePivotX", .Float, 0, 1, nil, "a layer's tile pivot"},
	{.Layer, "tilePivotY", .Float, 0, 1, nil, "a layer's tile pivot"},

	// Entities (EditEntityDefs)
	{.Entity, "doc", .Nullable_String, 0, 0, nil, "an entity type's documentation"},
	{.Entity, "tags", .Tags, 0, 0, nil, "an entity type's tags"},
	{.Entity, "exportToToc", .Bool, 0, 0, nil, "whether an entity type is in the table of contents"},
	{.Entity, "allowOutOfBounds", .Bool, 0, 0, nil, "whether an entity type may leave its level"},
	{.Entity, "width", .Int, 1, 2048, nil, "an entity type's size"},
	{.Entity, "height", .Int, 1, 2048, nil, "an entity type's size"},
	{.Entity, "resizableX", .Bool, 0, 0, nil, "whether an entity type is resizable"},
	{.Entity, "resizableY", .Bool, 0, 0, nil, "whether an entity type is resizable"},
	{.Entity, "keepAspectRatio", .Bool, 0, 0, nil, "whether an entity type keeps its aspect"},
	{.Entity, "minWidth", .Nullable_Int, 0, 100000, nil, "an entity type's size limits"},
	{.Entity, "maxWidth", .Nullable_Int, 0, 100000, nil, "an entity type's size limits"},
	{.Entity, "minHeight", .Nullable_Int, 0, 100000, nil, "an entity type's size limits"},
	{.Entity, "maxHeight", .Nullable_Int, 0, 100000, nil, "an entity type's size limits"},
	{.Entity, "tileOpacity", .Float, 0, 1, nil, "an entity type's opacities"},
	{.Entity, "fillOpacity", .Float, 0, 1, nil, "an entity type's opacities"},
	{.Entity, "lineOpacity", .Float, 0, 1, nil, "an entity type's opacities"},
	{.Entity, "hollow", .Bool, 0, 0, nil, "whether an entity type is hollow"},
	{.Entity, "color", .Color, 0, 0, nil, "an entity type's color"},
	{.Entity, "render", .Special, 0, 0, nil, "how an entity type is drawn"},
	{.Entity, "showName", .Bool, 0, 0, nil, "whether an entity type shows its name"},
	{.Entity, "tileRenderMode", .Choice, 0, 0, LDTK_TILE_RENDER_MODES, "how an entity type's tile fits"},
	{.Entity, "tileRect", .Rect, 0, 0, nil, "an entity type's tile"},
	{.Entity, "uiTileset", .Special, 0, 0, nil, "an entity type's editor tile"},
	{.Entity, "uiTileRect", .Rect, 0, 0, nil, "an entity type's editor tile"},
	{.Entity, "nineSliceBorders", .Special, 1, 100000, nil, "an entity type's 9-slice borders"},
	{.Entity, "maxCount", .Int, 0, 1024, nil, "an entity type's count limit"},
	{.Entity, "limitScope", .Choice, 0, 0, LDTK_LIMIT_SCOPES, "an entity type's count limit"},
	{.Entity, "limitBehavior", .Choice, 0, 0, LDTK_LIMIT_BEHAVIORS, "an entity type's count limit"},
	{.Entity, "pivotX", .Float, 0, 1, nil, "an entity type's pivot"},
	{.Entity, "pivotY", .Float, 0, 1, nil, "an entity type's pivot"},

	// Fields (FieldDefsForm), entities' and levels'
	{.Field, "identifier", .Special, 0, 0, nil, "a field's name"},
	{.Field, "doc", .Nullable_String, 0, 0, nil, "a field's documentation"},
	{.Field, "editorDisplayMode", .Choice, 0, 0, LDTK_DISPLAY_MODES, "how a field shows"},
	{.Field, "editorDisplayPos", .Choice, 0, 0, LDTK_DISPLAY_POSITIONS, "where a field shows"},
	{.Field, "editorLinkStyle", .Choice, 0, 0, LDTK_LINK_STYLES, "a field's link style"},
	{.Field, "editorDisplayScale", .Float, 0.1, 100, nil, "a field's display scale"},
	{.Field, "editorDisplayColor", .Nullable_Color, 0, 0, nil, "a field's display color"},
	{.Field, "editorShowInWorld", .Bool, 0, 0, nil, "whether a field shows in the world view"},
	{.Field, "editorAlwaysShow", .Bool, 0, 0, nil, "whether a field always shows"},
	{.Field, "editorCutLongValues", .Bool, 0, 0, nil, "whether a field cuts long values"},
	{.Field, "editorTextPrefix", .Raw_String, 0, 0, nil, "a field's prefix"},
	{.Field, "editorTextSuffix", .Raw_String, 0, 0, nil, "a field's suffix"},
	{.Field, "canBeNull", .Bool, 0, 0, nil, "whether a field can be null"},
	{.Field, "useForSmartColor", .Bool, 0, 0, nil, "whether a field gives the color"},
	{.Field, "exportToToc", .Bool, 0, 0, nil, "whether a field is in the table of contents"},
	{.Field, "searchable", .Bool, 0, 0, nil, "whether a field is searchable"},
	{.Field, "arrayMinLength", .Nullable_Int, 0, 99999, nil, "an array's size limits"},
	{.Field, "arrayMaxLength", .Nullable_Int, 0, 99999, nil, "an array's size limits"},
	{.Field, "min", .Special, 0, 0, nil, "a field's range"},
	{.Field, "max", .Special, 0, 0, nil, "a field's range"},
	{.Field, "defaultOverride", .Special, 0, 0, nil, "a field's default"},
	{.Field, "regex", .Special, 0, 0, nil, "a field's regular expression"},
	{.Field, "regexFlagI", .Special, 0, 0, nil, "a field's regular expression"},
	{.Field, "acceptFileTypes", .Special, 0, 0, nil, "a field's file types"},
	{.Field, "textLanguageMode", .Nullable_Choice, 0, 0, LDTK_TEXT_LANGUAGES, "a field's text language"},
	{.Field, "symmetricalRef", .Bool, 0, 0, nil, "whether references are symmetrical"},
	{.Field, "autoChainRef", .Bool, 0, 0, nil, "whether references chain"},
	{.Field, "allowOutOfLevelRef", .Bool, 0, 0, nil, "whether references leave the level"},
	{.Field, "allowedRefs", .Special, 0, 0, LDTK_ALLOWED_REFS, "what references point at"},
	{.Field, "allowedRefsEntityUid", .Uid, 0, 0, nil, "what references point at"},
	{.Field, "allowedRefTags", .Tags, 0, 0, nil, "what references point at"},
	{.Field, "tilesetUid", .Uid, 0, 0, nil, "a tile field's tileset"},

	// Enums (EditEnumDefs)
	{.Enum, "tags", .Tags, 0, 0, nil, "an enum's tags"},
	{.Enum, "iconTilesetUid", .Uid, 0, 0, nil, "an enum's icons"},

	// Tilesets (EditTilesetDefs)
	{.Tileset, "identifier", .Special, 0, 0, nil, "a tileset's name"},
	{.Tileset, "relPath", .Special, 0, 0, nil, "a tileset's image"},
	{.Tileset, "tileGridSize", .Special, 2, LDTK_MAX_GRID_SIZE, nil, "a tileset's grid"},
	{.Tileset, "spacing", .Int, 0, LDTK_MAX_GRID_SIZE, nil, "a tileset's spacing"},
	{.Tileset, "padding", .Int, 0, LDTK_MAX_GRID_SIZE, nil, "a tileset's padding"},
	{.Tileset, "tags", .Tags, 0, 0, nil, "a tileset's tags"},
	{.Tileset, "tagsSourceEnumUid", .Uid, 0, 0, nil, "a tileset's tag enum"},
}

// A member by list and key (nil: none)
LDtkDefs_Member :: proc(kind: LDtkDefKind, key: string) -> ^LDtkMember {
	for &m in LDTK_MEMBERS do if m.kind == kind && m.key == key do return &m
	return nil
}

// What a `Def_Set` edit's undo step says ("Change a layer's grid size")
LDtkDefs_SetLabel :: proc(edit: LDtk_Edit) -> string {
	if m := LDtkDefs_Member(edit.kind, edit.key); m != nil do return fmt.tprintf("Change %s", m.label)
	return "Change a definition"
}

// The definitions' list of a kind in `defs` ("layers"...; fields: "" (an entity's `fieldDefs` or `levelFields`))
@(private)
defListName :: proc(kind: LDtkDefKind) -> string {
	switch kind {
	case .Layer: return "layers"
	case .Entity: return "entities"
	case .Enum: return "enums"
	case .Tileset: return "tilesets"
	case .Field: return ""
	}
	return ""
}

// A definition's node by kind and uid (-1 none; an external enum counts)
LDtkDefs_Node :: proc(doc: ^LDtkDoc, kind: LDtkDefKind, uid: int) -> int {
	if kind == .Field {
		_, node := LDtkDoc_FieldDef(doc, uid)
		return node
	}
	node := LDtkDoc_DefByUid(doc, defListName(kind), uid)
	if node < 0 && kind == .Enum do node = LDtkDoc_DefByUid(doc, "externalEnums", uid)
	return node
}

/*
An identifier made unique as LDtk makes it (Project.fixUniqueIdStr): cleaned up with the style
("Unnamed" when nothing is left), then, while taken, counted on: a name ending in a number from
that number ("Layer4" → "Layer5"), else from 2 ("Entity" → "Entity2").

Returns:
- The identifier (temp allocated)
*/
ldtkUniqueId :: proc(base, style: string, taken: map[string]bool) -> string {
	id, ok := LDtk_CleanIdentifier(base, style)
	if !ok || id == "_" do id = "Unnamed"
	if id not_in taken do return id
	i := len(id)
	for i > 0 && id[i - 1] >= '0' && id[i - 1] <= '9' do i -= 1
	if i < len(id) && i > 0 {
		prefix := id[:i]
		n, _ := strconv.parse_int(id[i:])
		for {
			candidate := fmt.tprintf("%s%d", prefix, n)
			if candidate not_in taken do return candidate
			n += 1
		}
	}
	n := 2
	for {
		candidate := fmt.tprintf("%s%d", id, n)
		if candidate not_in taken do return candidate
		n += 1
	}
}

// The identifiers a list's definitions have (temp)
@(private)
defIdentifiers :: proc(main: ^JsonDoc, list: int, key := "identifier", except := -1) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	for d in Json_Items(main, list) do if d != except do out[strings.clone(Json_String(main, Json_Get(main, d, key)), context.temp_allocator)] = true
	return out
}

/*
A definition's member written (added at the object's end when it lacks it), as LDtk writes the
value; nothing when it already holds it.
*/
@(private)
defWrite :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, node: int, key: string, v: LDtkJV) {
	main := LDtkDoc_Main(doc)
	member := Json_Get(main, node, key)
	minified := Json_Minified(main)
	if member >= 0 {
		if jvSame(main, member, v) do return
		LDtkPatches_Add(p, 0, Json_SetPatch(main, member, writeAt(main, member, v, minified)))
		return
	}
	indent := LDtk_IndentAt(main.text, int(main.nodes[node].start)) + 1
	LDtkPatches_Add(p, 0, Json_AddMemberPatch(main, node, key, LDtk_PrettyJson(v, minified, indent)))
}

// The project's identifier style
@(private)
defStyle :: proc(doc: ^LDtkDoc) -> string {
	main := LDtkDoc_Main(doc)
	return Json_String(main, Json_Get(main, Json_Root(main), "identifierStyle"))
}

// Uids for new definitions, from the project's `nextUid` (written back by `uidsDone`)
@(private)
Uids :: struct {
	next, start: int,
}

@(private)
uidsMake :: proc(doc: ^LDtkDoc) -> Uids {
	main := LDtkDoc_Main(doc)
	n := Json_Int(main, Json_Get(main, Json_Root(main), "nextUid"), 1)
	return {next = n, start = n}
}

@(private)
uidTake :: proc(u: ^Uids) -> int {
	u.next += 1
	return u.next - 1
}

// `nextUid` written past the uids taken
@(private)
uidsDone :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, u: Uids) {
	if u.next == u.start do return
	main := LDtkDoc_Main(doc)
	LDtkPatches_Set(p, doc, 0, Json_Get(main, Json_Root(main), "nextUid"), fmt.tprint(u.next))
}

/*
Tags typed as LDtk's TagEditor keeps them (Tags.set: each cleaned up with the Free style, "_"
and empty ones dropped, each once, in order).
*/
LDtk_ParseTags :: proc(text: string) -> LDtkJV {
	out := make([dynamic]LDtkJV, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for part in strings.fields_proc(text, proc(r: rune) -> bool { return r == ',' || r == ' ' || r == '\t' || r == ';' }, context.temp_allocator) {
		tag, ok := LDtk_CleanIdentifier(part, "Free")
		if !ok || tag == "_" || tag in seen do continue
		seen[tag] = true
		append(&out, tag)
	}
	return LDtkJArray(out[:])
}

// A tile rectangle from "x,y,w,h" (false when it isn't one)
LDtk_ParseRect :: proc(text: string) -> (r: [4]int, ok: bool) {
	parts := strings.split(strings.trim_space(text), ",", context.temp_allocator)
	if len(parts) != 4 do return {}, false
	for part, i in parts {
		v, parsed := strconv.parse_int(strings.trim_space(part))
		if !parsed do return {}, false
		r[i] = v
	}
	return r, true
}

// A tile rectangle's value (LDtk's TilesetRect)
@(private)
rectJV :: proc(tileset: int, r: [4]int) -> LDtkJV {
	return jobject(jpair("tilesetUid", i64(tileset)), jpair("x", i64(r[0])), jpair("y", i64(r[1])), jpair("w", i64(r[2])), jpair("h", i64(r[3])))
}

// A number typed or stepped: `text` when it holds one, else `number`
@(private)
editNumber :: proc(edit: LDtk_Edit) -> (f64, bool) {
	if t := strings.trim_space(edit.text); t != "" {
		v, ok := strconv.parse_f64(t)
		return v, ok
	}
	return edit.number, true
}

/*
A member's new value from an edit, by its kind (bounds applied; null where the kind allows).

Returns:
- The value, and why not when the edit holds no value of the kind
*/
@(private)
memberValue :: proc(doc: ^LDtkDoc, m: ^LDtkMember, edit: LDtk_Edit) -> (LDtkJV, string) {
	t := strings.trim_space(edit.text)
	switch m.type {
	case .Bool: return edit.flag, ""
	case .Int:
		v, ok := editNumber(edit)
		if !ok do return nil, fmt.tprintf("%q isn't a whole number", edit.text)
		return i64(clamp(math.round(v), m.lo, m.hi)), ""
	case .Float:
		v, ok := editNumber(edit)
		if !ok do return nil, fmt.tprintf("%q isn't a number", edit.text)
		return jvNumber(ldtkWriteFloat(clamp(v, m.lo, m.hi))), ""
	case .Nullable_Int:
		if t == "" do return LDtkJNull{}, ""
		v, ok := strconv.parse_f64(t)
		if !ok do return nil, fmt.tprintf("%q isn't a whole number", edit.text)
		return i64(clamp(math.round(v), m.lo, m.hi)), ""
	case .Nullable_Float:
		if t == "" do return LDtkJNull{}, ""
		v, ok := strconv.parse_f64(t)
		if !ok do return nil, fmt.tprintf("%q isn't a number", edit.text)
		return jvNumber(clamp(v, m.lo, m.hi)), ""
	case .Nullable_String:
		if t == "" do return LDtkJNull{}, ""
		return strings.clone(edit.text, context.temp_allocator), ""
	case .Raw_String:
		if edit.text == "" do return LDtkJNull{}, ""
		return strings.clone(edit.text, context.temp_allocator), ""
	case .Color, .Nullable_Color:
		if t == "" && m.type == .Nullable_Color do return LDtkJNull{}, ""
		c, ok := LDtk_ParseColor(t)
		if !ok do return nil, fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text)
		return LDtk_FormatColor(c), ""
	case .Choice, .Nullable_Choice:
		if t == "" && m.type == .Nullable_Choice do return LDtkJNull{}, ""
		if !slice.contains(m.choices, t) do return nil, fmt.tprintf("%q isn't one of %v", edit.text, m.choices)
		return strings.clone(t, context.temp_allocator), ""
	case .Uid:
		if t == "" || t == "-1" do return LDtkJNull{}, ""
		v, ok := strconv.parse_int(t)
		if !ok do return nil, fmt.tprintf("%q isn't a definition", edit.text)
		return i64(v), ""
	case .Tags: return LDtk_ParseTags(edit.text), ""
	case .Rect:
		if t == "" do return LDtkJNull{}, ""
		r, ok := LDtk_ParseRect(t)
		if !ok do return nil, fmt.tprintf("%q isn't a tile rectangle (x,y,w,h)", edit.text)
		return rectJV(int(math.round(edit.number)), r), ""
	case .Special:
	}
	return nil, "not a plain member"
}

// What a definition edit also asks for, after its definition changed (see `LDtkOps_DefEdit`)
@(private)
DefOp :: struct {
	s: ^Stages,
	edit: LDtk_Edit,
	// The tidy's extra passes
	scope: LDtkTidyScope,
	// Layer definitions whose auto-layer rules are applied again in every level (their tiles
	// depend on what changed)
	rerun: map[int]bool,
	// Tilesets whose pixel data (`cachedPixelData`) is made again from their image
	pixels: map[int]bool,
	// The project folder (external enums, images)
	root: string,
}

/*
Makes a definitions editor edit (`Def_*`, `Field_Converted`, IntGrid values and groups, enum
values and external enums, tilesets' tiles) in the document in memory: the definition, LDtk's
consequences, every level brought in step (LDtk's tidy), the table of contents. One undo step.

Inputs:
- root: The project folder
- doc: The document

Returns:
- "" or why nothing changed; a rename scenes follow (none here: renames are their own ops)
*/
LDtkOps_DefEdit :: proc(root: string, doc: ^LDtkDoc, edit: LDtk_Edit) -> (problem: string, rename: LDtkRename) {
	s := stagesMake(doc)
	op := DefOp{s = &s, edit = edit, rerun = make(map[int]bool, context.temp_allocator), pixels = make(map[int]bool, context.temp_allocator), root = root}
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	#partial switch edit.op {
	case .Def_Set:
		problem = defSet(&op)
	case .Def_Added:
		problem = defAdded(&op)
	case .Def_Removed:
		problem = defRemoved(&op)
	case .Def_Duplicated:
		problem = defDuplicated(&op)
	case .Def_Moved:
		problem = defMoved(&op)
	case .Field_Converted:
		problem = fieldConverted(&op)
	case .IntGrid_Value_Added, .IntGrid_Value_Removed, .IntGrid_Value_Moved, .IntGrid_Value_Tile,
	     .IntGrid_Group_Added, .IntGrid_Group_Removed, .IntGrid_Group_Set, .IntGrid_Group_Moved:
		problem = intGridEdit(&op)
	case .Enum_Value_Removed, .Enum_Value_Moved, .Enum_Value_Tile:
		problem = enumValueEdit(&op)
	case .Enum_Import, .Enum_Sync, .Enum_External_Removed:
		problem = externalEnumEdit(&op)
	case .Tileset_Tag, .Tileset_Custom_Data:
		problem = tilesetTileEdit(&op)
	case:
		problem = "not a definition edit"
	}
	if problem != "" do return problem, {}
	if len(s.made) == 0 do return "", {}
	if len(op.pixels) > 0 {
		if problem = pixelsStage(&op); problem != "" do return problem, {}
	}
	if problem = LDtkTidy_Run(&s, op.scope); problem != "" do return problem, {}
	if len(op.rerun) > 0 {
		if problem = rerunRules(&s, op.rerun); problem != "" do return problem, {}
	}
	result := stagesFinish(&s, "")
	s.made = nil
	return result, {}
}

/*
Applies every rule of the given layers again in every level (LayerInstance.applyAllRules), and
of the AutoLayers built from them, writing their tiles as LDtk does.
*/
@(private)
rerunRules :: proc(s: ^Stages, layers: map[int]bool) -> string {
	p := LDtkPatches{}
	doc := s.cur
	main := LDtkDoc_Main(doc)
	// AutoLayers built from a rerun IntGrid layer follow it
	all := make(map[int]bool, context.temp_allocator)
	for uid in layers do all[uid] = true
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		source := nodeUid(main, Json_Get(main, d, "autoSourceLayerDefUid"))
		if source >= 0 && source in layers do all[Json_Int(main, Json_Get(main, d, "uid"))] = true
	}
	for _, level in doc.levels {
		m, ok := LDtkLevel_Read(doc, "", level)
		if !ok do continue
		defer LDtkLevel_Destroy(&m)
		changed := false
		for &l in m.layers {
			d := LDtkLevel_Def(&m, &l)
			if d.uid not_in all || !LDtkLayerInfo_IsAuto(d) do continue
			LDtkRules_ApplyAll(&m, &l)
			l.changed += {.Auto}
			changed = true
		}
		if !changed do continue
		more := LDtkLevel_Patches(&m, doc)
		for list, file in more.files do for patch in list do LDtkPatches_Add(&p, file, patch)
	}
	return stagesApply(s, &p)
}
