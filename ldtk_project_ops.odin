package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

/*
The Project tab's edits (phase 5 of TODO.md's "LDtk level editor"): every option of LDtk's project
panel (its ui/modal/panel/EditProject.hx, app/assets/tpl/editProject.html, data/Project.hx), each
with what LDtk does beside it:

- **Saving:** levels in separate files (`externalLevels`: each level's layers move to its `.ldtkl`
  file or back; ldtk_level_ops.odin's `externalLevelsSet`), minified JSON (`minifyJson`: every file
  written again by LDtk's writer, minified or pretty), the "super simple" export
  (`simplifiedExport`), image export (`imageExportMode`, which resets `pngFilePattern` as LDtk's
  select does; `exportLevelBg`; the file name pattern, null when it's the mode's default), Tiled
  export (`exportTiled`), backups (`backupOnSave`, `backupLimit` 3 to 50, `backupRelPath`).
  What each makes on Save is ldtk_save_extras.odin's.
- **Identifiers:** the style (`identifierStyle`: LDtk's Project.applyIdentifierStyleEverywhere, every
  enum, value, layer, entity type, tileset, world and level named again, local enum values in
  fields with them), the level name pattern (`levelNamePattern`: automatic names follow).
- **Defaults:** grid size, entity size, entity pivot, the workspace's and new levels' background
  colors (levels using the default follow).
- **Advanced flags** (`Project_Flag`): MultiWorlds (the levels move into `worlds` or back:
  `multiWorldsSet`; off only with one world), PrependIndexToLevelFileNames (the level files are
  named again), ExportPreCsvIntGridFormat (IntGrid layers also get LDtk's legacy `intGrid` array),
  UseMultilinesType (`__type` Multilines), ExportOldTableOfContentData (the table of contents'
  `instances`).
- **Custom commands** (`Project_Command`): listed, added, removed, reordered, their text and when
  they run. They're kept for LDtk; the editor doesn't run them (decided: a project file could make
  it run any program; LDtk asks the user to trust a project first, and its commands run in LDtk).
- **The sample description** (`tutorialDesc`).

Each edit is one undo step, then LDtk's tidy (what its consequences change in the levels).
*/

// LDtk's image export modes (ldtk.Json.ImageExportMode)
LDTK_IMAGE_EXPORT_MODES :: []string{"None", "OneImagePerLayer", "OneImagePerLevel", "LayersAndLevels"}
// LDtk's identifier styles (ldtk.Json.IdentifierStyle)
LDTK_IDENTIFIER_STYLES :: []string{"Capitalize", "Uppercase", "Lowercase", "Free"}
// When a custom command runs (ldtk.Json.CustomCommandTrigger)
LDTK_COMMAND_TRIGGERS :: []string{"Manual", "AfterLoad", "BeforeSave", "AfterSave"}
// The flags the Project tab shows (EditProject's allAdvancedOptions)
LDTK_ADVANCED_FLAGS :: []string{"MultiWorlds", "PrependIndexToLevelFileNames", "ExportPreCsvIntGridFormat", "UseMultilinesType", "ExportOldTableOfContentData"}
// LDtk's backup limit's default and bounds (Const.DEFAULT_BACKUP_LIMIT, EditProject's setBounds)
LDTK_BACKUP_LIMIT :: 10

/*
The image file name pattern LDtk uses by default for an export mode (Project.getDefaultImageExportFilePattern).
*/
LDtk_DefaultPngPattern :: proc(mode: string) -> string {
	return mode == "OneImagePerLevel" ? "%level_name" : "%level_name__%layer_name"
}

/*
Makes a Project tab edit (`Project_Set`, `Project_Flag`, `Project_Command`) in the document in
memory.

Returns:
- "" or why nothing changed
*/
LDtkOps_ProjectEdit :: proc(root: string, doc: ^LDtkDoc, edit: LDtk_Edit) -> (problem: string) {
	s := stagesMake(doc)
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	#partial switch edit.op {
	case .Project_Set:     problem = projectSet(&s, edit)
	case .Project_Flag:    problem = projectFlag(&s, edit)
	case .Project_Command: problem = projectCommand(&s, edit)
	case:                  problem = "not a project edit"
	}
	if problem != "" do return
	if len(s.made) == 0 do return ""
	return LDtkOps_LevelsFinish(&s)
}

@(private="file")
projectSet :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	doc := s.cur
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	p := LDtkPatches{}
	t := strings.trim_space(edit.text)
	number :: proc(edit: LDtk_Edit, lo, hi: f64) -> (i64, string) {
		v, ok := editNumber(edit)
		if !ok do return 0, fmt.tprintf("%q isn't a whole number", edit.text)
		return i64(clamp(math.round(v), lo, hi)), ""
	}
	switch edit.key {
	case "externalLevels":
		return externalLevelsSet(s, edit.flag)
	case "minifyJson":
		defWrite(&p, doc, root, "minifyJson", edit.flag)
		if problem := stagesApply(s, &p); problem != "" do return problem
		return reprintAll(s, edit.flag)
	case "simplifiedExport", "exportTiled", "exportLevelBg", "backupOnSave":
		defWrite(&p, doc, root, edit.key, edit.flag)
	case "imageExportMode":
		if !slice.contains(LDTK_IMAGE_EXPORT_MODES, t) do return fmt.tprintf("%q isn't one of %v", edit.text, LDTK_IMAGE_EXPORT_MODES)
		defWrite(&p, doc, root, "imageExportMode", strings.clone(t, context.temp_allocator))
		// EditProject's select: a new mode starts with its own default pattern
		defWrite(&p, doc, root, "pngFilePattern", LDtkJNull{})
	case "pngFilePattern":
		mode := Json_String(main, Json_Get(main, root, "imageExportMode"))
		if t == "" || t == LDtk_DefaultPngPattern(mode) do defWrite(&p, doc, root, "pngFilePattern", LDtkJNull{})
		else do defWrite(&p, doc, root, "pngFilePattern", strings.clone(t, context.temp_allocator))
	case "backupLimit":
		n, why := number(edit, 3, 50)
		if why != "" do return why
		defWrite(&p, doc, root, "backupLimit", n)
	case "backupRelPath":
		defWrite(&p, doc, root, "backupRelPath", t == "" ? LDtkJV(LDtkJNull{}) : LDtkJV(strings.clone(t, context.temp_allocator)))
	case "levelNamePattern":
		defWrite(&p, doc, root, "levelNamePattern", t == "" ? LDTK_DEFAULT_LEVEL_NAME_PATTERN : strings.clone(t, context.temp_allocator))
	case "identifierStyle":
		if !slice.contains(LDTK_IDENTIFIER_STYLES, t) do return fmt.tprintf("%q isn't one of %v", edit.text, LDTK_IDENTIFIER_STYLES)
		if Json_String(main, Json_Get(main, root, "identifierStyle")) == t do return ""
		defWrite(&p, doc, root, "identifierStyle", strings.clone(t, context.temp_allocator))
		if problem := stagesApply(s, &p); problem != "" do return problem
		return identifierStyleEverywhere(s)
	case "defaultGridSize":
		n, why := number(edit, 1, LDTK_MAX_GRID_SIZE)
		if why != "" do return why
		defWrite(&p, doc, root, "defaultGridSize", n)
	case "defaultEntityWidth", "defaultEntityHeight":
		n, why := number(edit, 1, LDTK_MAX_GRID_SIZE)
		if why != "" do return why
		defWrite(&p, doc, root, edit.key, n)
	case "bgColor", "defaultLevelBgColor":
		c, ok := LDtk_ParseColor(t)
		if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text)
		defWrite(&p, doc, root, edit.key, LDtk_FormatColor(c))
	case "defaultPivot":
		defWrite(&p, doc, root, "defaultPivotX", jvNumber(ldtkWriteFloat(clamp(edit.number, 0, 1))))
		defWrite(&p, doc, root, "defaultPivotY", jvNumber(ldtkWriteFloat(clamp(edit.number2, 0, 1))))
	case "tutorialDesc":
		// dn.Lib.trimEmptyLines, null when nothing's left; written escaped (JsonTools.escapeString)
		lines := strings.split(edit.text, "\n", context.temp_allocator)
		first, last := 0, len(lines) - 1
		for first <= last && strings.trim_space(lines[first]) == "" do first += 1
		for last >= first && strings.trim_space(lines[last]) == "" do last -= 1
		desc := first <= last ? strings.join(lines[first:last + 1], "\n", context.temp_allocator) : ""
		defWrite(&p, doc, root, "tutorialDesc", desc == "" ? LDtkJV(LDtkJNull{}) : LDtkJV(desc))
	case:
		return fmt.tprintf("an LDtk project has no setting %q here", edit.key)
	}
	return stagesApply(s, &p)
}

// One of LDtk's advanced flags on or off (Editor.setProjectFlag)
@(private="file")
projectFlag :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	if !slice.contains(LDTK_PROJECT_FLAGS, edit.key) do return fmt.tprintf("%q isn't one of LDtk's flags", edit.key)
	doc := s.cur
	if edit.key == "MultiWorlds" do return multiWorldsSet(s, edit.flag)
	if LDtkDoc_HasFlag(doc, edit.key) == edit.flag do return ""
	main := LDtkDoc_Main(doc)
	p := LDtkPatches{}
	defWrite(&p, doc, Json_Root(main), "flags", flagsWith(doc, edit.key, edit.flag))
	return stagesApply(s, &p)
}

// The custom commands: added, removed, moved, their text or trigger
@(private="file")
projectCommand :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	doc := s.cur
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	list := Json_Get(main, root, "customCommands")
	items := make([dynamic]LDtkJV, context.temp_allocator)
	for c in Json_Items(main, list) do append(&items, ldtkJV(main, c))
	i := edit.index
	switch edit.key {
	case "add":
		append(&items, jobject(jpair("command", ""), jpair("when", "Manual")))
	case "remove":
		if i < 0 || i >= len(items) do return "no such command"
		ordered_remove(&items, i)
	case "move":
		if i < 0 || i >= len(items) do return "no such command"
		to := clamp(int(math.round(edit.number)), 0, len(items) - 1)
		if to == i do return ""
		moved := items[i]
		ordered_remove(&items, i)
		inject_at(&items, to, moved)
	case "command":
		if i < 0 || i >= len(items) do return "no such command"
		items[i] = jvWith(items[i], "command", strings.clone(edit.text, context.temp_allocator))
	case "when":
		if i < 0 || i >= len(items) do return "no such command"
		t := strings.trim_space(edit.text)
		if !slice.contains(LDTK_COMMAND_TRIGGERS, t) do return fmt.tprintf("%q isn't one of %v", edit.text, LDTK_COMMAND_TRIGGERS)
		items[i] = jvWith(items[i], "when", strings.clone(t, context.temp_allocator))
	case:
		return fmt.tprintf("%q isn't a command edit", edit.key)
	}
	p := LDtkPatches{}
	defWrite(&p, doc, root, "customCommands", LDtkJArray(items[:]))
	return stagesApply(s, &p)
}

/*
Every file written again by LDtk's writer (JsonPretty), minified or pretty (`minifyJson`): LDtk
writes each file whole on its next save.
*/
@(private="file")
reprintAll :: proc(s: ^Stages, minified: bool) -> string {
	doc := s.cur
	p := LDtkPatches{}
	for _, i in doc.files {
		json := LDtkDoc_Json(doc, i)
		root := Json_Root(json)
		LDtkPatches_Set(&p, doc, i, root, LDtk_PrettyJson(ldtkJV(json, root), minified, 0))
	}
	return stagesApply(s, &p)
}

/*
LDtk's Project.applyIdentifierStyleEverywhere: enums and their values, layers, entity types,
tilesets (and their local tag enum's tags), worlds and levels cleaned up with the new style, and
local enum values in levels' and entities' fields with them. What mirrors them (`__identifier`,
`__type`, the table of contents) follows through the tidy.
*/
@(private="file")
identifierStyleEverywhere :: proc(s: ^Stages) -> string {
	doc := s.cur
	main := LDtkDoc_Main(doc)
	style := defStyle(doc)
	p := LDtkPatches{}
	clean :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, node: int, style: string) {
		json := LDtkDoc_Json(doc, file)
		if Json_Kind(json, node) != .String do return
		old := Json_String(json, node)
		if id, ok := LDtk_CleanIdentifier(old, style); ok && id != old do LDtkPatches_Set(p, doc, file, node, Json_Quote(id))
	}
	localEnums := make(map[int]bool, context.temp_allocator)
	for ed in Json_Items(main, LDtkDoc_Defs(doc, "enums")) {
		localEnums[Json_Int(main, Json_Get(main, ed, "uid"))] = true
		clean(&p, doc, 0, Json_Get(main, ed, "identifier"), style)
		for v in Json_Items(main, Json_Get(main, ed, "values")) do clean(&p, doc, 0, Json_Get(main, v, "id"), style)
	}
	for list in ([]string{"layers", "entities", "tilesets"}) do for d in Json_Items(main, LDtkDoc_Defs(doc, list)) do clean(&p, doc, 0, Json_Get(main, d, "identifier"), style)
	for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) {
		if Json_Int(main, Json_Get(main, td, "tagsSourceEnumUid"), -1) not_in localEnums do continue
		for tag in Json_Items(main, Json_Get(main, td, "enumTags")) do clean(&p, doc, 0, Json_Get(main, tag, "enumValueId"), style)
	}
	if LDtkDoc_MultiWorlds(doc) do for _, w in doc.worlds do clean(&p, doc, 0, Json_Get(main, doc.worlds[w].object, "identifier"), style)
	for _, l in doc.levels do for place in LDtkDoc_LevelObjects(doc, l) {
		clean(&p, doc, place.file, Json_Get(LDtkDoc_Json(doc, place.file), place.node, "identifier"), style)
	}
	// Local enum values in fields (FieldInstance.parseValue of the cleaned value)
	enumFields := make(map[int]bool, context.temp_allocator)
	for f in ldtkAllFieldDefsOf(doc) {
		info := LDtkDoc_FieldInfo(doc, f)
		if info.type == .Enum && info.enumUid in localEnums do enumFields[info.uid] = true
	}
	for fi in ldtkAllFieldInstances(doc) {
		json := LDtkDoc_Json(doc, fi.file)
		if Json_Int(json, Json_Get(json, fi.node, "defUid"), -1) not_in enumFields do continue
		for raw in Json_Items(json, Json_Get(json, fi.node, "realEditorValues")) do for v in Json_Items(json, Json_Get(json, raw, "params")) do clean(&p, doc, fi.file, v, style)
	}
	return stagesApply(s, &p)
}

// Every field definition (entities' and levels'; temp)
@(private="file")
ldtkAllFieldDefsOf :: proc(doc: ^LDtkDoc) -> []int {
	main := LDtkDoc_Main(doc)
	out := make([dynamic]int, context.temp_allocator)
	for e in Json_Items(main, LDtkDoc_Defs(doc, "entities")) do append(&out, ..Json_Items(main, Json_Get(main, e, "fieldDefs")))
	append(&out, ..Json_Items(main, LDtkDoc_Defs(doc, "levelFields")))
	return out[:]
}

/*
LDtk's legacy IntGrid data (LayerInstance.toJson with the ExportPreCsvIntGridFormat flag): every
layer instance gets an `intGrid` array last, `{ "coordId": i, "v": value - 1 }` for each cell with a
value, in coordinate order; without the flag the array isn't written (a file that has one loses it,
as LDtk's next save drops it).
*/
@(private)
tidyLegacyIntGrid :: proc(p: ^LDtkPatches, doc: ^LDtkDoc) {
	flag := LDtkDoc_HasFlag(doc, "ExportPreCsvIntGridFormat")
	for _, l in doc.levels {
		file, array := LDtkDoc_LayerInstances(doc, l)
		json := LDtkDoc_Json(doc, file)
		for li in Json_Items(json, array) {
			member := Json_Get(json, li, "intGrid")
			if !flag {
				if member >= 0 do LDtkPatches_Add(p, file, Json_RemovePatch(json, member))
				continue
			}
			cells := make([dynamic]LDtkJV, context.temp_allocator)
			for v, i in Json_Items(json, Json_Get(json, li, "intGridCsv")) {
				value := Json_Int(json, v)
				if value != 0 do append(&cells, jobject(jpair("coordId", i64(i)), jpair("v", i64(value - 1))))
			}
			want := LDtkJArray(cells[:])
			if member >= 0 {
				tidySet(p, doc, file, li, "intGrid", want)
				continue
			}
			// Added last, at its members' indentation
			n := json.nodes[li]
			if n.count == 0 do continue
			indent := LDtk_IndentAt(json.text, int(json.nodes[n.last].keyStart))
			LDtkPatches_Add(p, file, Json_AddMemberPatch(json, li, "intGrid", LDtk_PrettyJson(want, Json_Minified(json), indent)))
		}
	}
}
