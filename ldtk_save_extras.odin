package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import stbiw "vendor:stb/image"
import sdl "vendor:sdl3"
import "core:time"

/*
What LDtk's saver writes besides the project's own files (its ui/ProjectSaver.hx), when the Project
tab asks for it, every time the project is saved here (`LDtkDoc_Save`):

- **Backups** (`backupOnSave`): before the files are written, the project file and its level files
  as they were on disk are copied into `<backup folder>/<project iid>_<date>_<time>/` (the folder:
  `backupRelPath` from the project file, else `<project name>/backups`), and the oldest backups
  past `backupLimit` are removed (ProjectSaver.backupProjectFiles, listBackupFiles).
- **PNG pictures** (`imageExportMode`, into `<project name>/png/`, its old pictures replaced): one
  per layer (`OneImagePerLayer`: tiles and auto-layers at their opacity, an IntGrid layer's values
  also as a picture of a pixel per cell, `-int`), one per level (`OneImagePerLevel`), or both
  (`LayersAndLevels`); with the levels' backgrounds (`exportLevelBg`, `<level>_bg`); named by
  `pngFilePattern` (Project.getPngFileName). Drawn by the Level mode's renderer
  (level_layers_render.odin), the canvas's drawing, not LDtk's GPU: pixels where tiles are
  scaled or blended may differ slightly. `None` removes the folder.
- **The simplified export** (`simplifiedExport`, into `<project name>/simplified/<level>/`, written
  again whole): `data.json` (Level.toSimplifiedJson, JsonPretty's Full layout), a CSV per IntGrid
  layer (exporter/Csv.toString2D), and the pictures of LayersAndLevels (`_bg`, `<layer>`,
  `<layer>-int`, `_composite`). Off removes the folder.
- **Not made here (decided):** Tiled files (`exportTiled`: LDtk's exporter writes TMX for the first
  world only and says it's a workaround for frameworks that read only Tiled; the setting is kept, so
  LDtk writes them when it saves), LDtk's disabled GameMaker export, and custom commands (a project
  file could make the editor run any program; they're kept for LDtk).

Problems are logged by the caller and never stop the save (the project's own files are written).
*/

// A backup's folder name: the project's iid and the local date and time (ProjectSaver's makeBackupDirName)
@(private="file")
backupDirName :: proc(iid: string) -> string {
	dt: sdl.DateTime
	if !sdl.TimeToDateTime(sdl.Time(time.to_unix_nanoseconds(time.now())), &dt, true) do return fmt.tprintf("%s_backup", iid)
	return fmt.tprintf("%s_%04d-%02d-%02d_%02d-%02d-%02d", iid, dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
}

// Where a project's backups go (Project.getAbsBackupDir; temp)
LDtk_BackupFolder :: proc(doc: ^LDtkDoc) -> string {
	main := LDtkDoc_Main(doc)
	rel := Json_Get(main, Json_Root(main), "backupRelPath")
	if Json_Kind(main, rel) == .String do return joinPath(LDtkDoc_Folder(doc), Json_String(main, rel), allocator = context.temp_allocator)
	return joinPath(LDtk_LevelFilesFolder(doc.files[0].path), "backups", allocator = context.temp_allocator)
}

/*
Copies a project's files as they are on disk into a new backup, then removes the oldest past its
limit (ProjectSaver's Backup step: before the files are written). Nothing when `backupOnSave` is
off or the project file isn't on disk yet.

Returns:
- "" or what went wrong
*/
LDtkSave_Backup :: proc(doc: ^LDtkDoc) -> string {
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	if !Json_Bool(main, Json_Get(main, root, "backupOnSave")) do return ""
	project := doc.files[0].path
	if !os.exists(project) do return ""
	iid := Json_String(main, Json_Get(main, root, "iid"))
	backups := LDtk_BackupFolder(doc)
	target := joinPath(backups, backupDirName(iid), allocator = context.temp_allocator)
	files := make([dynamic][2]string, context.temp_allocator)
	append(&files, [2]string{project, joinPath(target, filepath.base(project), allocator = context.temp_allocator)})
	levels := LDtk_LevelFilesFolder(project)
	if entries, err := os.read_all_directory_by_path(levels, context.temp_allocator); err == nil {
		for entry in entries do if entry.type != .Directory && strings.has_suffix(entry.name, ".ldtkl") {
			append(&files, [2]string{entry.fullpath, joinPath(target, filepath.base(levels), entry.name, allocator = context.temp_allocator)})
		}
	}
	for f in files {
		_ = os.make_directory_all(filepath.dir(f[1]))
		if err := os.copy_file(f[1], f[0]); err != nil do return fmt.tprintf("couldn't back up %s: %v", filepath.base(f[0]), err)
	}
	limit := clamp(Json_Int(main, Json_Get(main, root, "backupLimit"), LDTK_BACKUP_LIMIT), 1, 50)
	LDtk_PruneBackups(backups, iid, limit)
	return ""
}

/*
Removes a project's oldest backups past `limit` (ProjectSaver.listBackupFiles: folders named
`<iid>_<YYYY-MM-DD>_<HH-MM-SS>` (or `backup_...`) holding an .ldtk or .json file, newest first).
*/
LDtk_PruneBackups :: proc(folder, iid: string, limit: int) {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil do return
	Backup :: struct {
		path, stamp: string,
	}
	found := make([dynamic]Backup, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory do continue
		if !strings.has_prefix(entry.name, iid) && !strings.has_prefix(entry.name, "backup_") do continue
		stamp, ok := backupStamp(entry.name)
		if !ok do continue
		inner, _ := os.read_all_directory_by_path(entry.fullpath, context.temp_allocator)
		project := false
		for f in inner do if strings.has_suffix(strings.to_lower(f.name, context.temp_allocator), ".ldtk") || strings.has_suffix(strings.to_lower(f.name, context.temp_allocator), ".json") do project = true
		if project do append(&found, Backup{entry.fullpath, stamp})
	}
	slice.sort_by(found[:], proc(a, b: Backup) -> bool { return a.stamp > b.stamp })
	for b, i in found do if i >= limit do _ = removeAll(b.path)
}

// A backup folder's date and time ("YYYY-MM-DD_HH-MM-SS"), from its name (ProjectSaver's regex)
@(private="file")
backupStamp :: proc(name: string) -> (string, bool) {
	// <anything>_YYYY-MM-DD_HH-MM-SS[_crash]
	n := strings.trim_suffix(name, "_crash")
	if len(n) < 20 do return "", false
	stamp := n[len(n) - 19:]
	if n[len(n) - 20] != '_' do return "", false
	for c, i in stamp {
		digit := c >= '0' && c <= '9'
		switch i {
		case 4, 7, 13, 16: if c != '-' do return "", false
		case 10: if c != '_' do return "", false
		case: if !digit do return "", false
		}
	}
	return stamp, true
}

/*
The pictures and the simplified export after the files are written (ProjectSaver's WritingImages,
WritingSimplifiedFormat), or their folders removed when they're off.

Returns:
- "" or what went wrong (temp)
*/
LDtkSave_Exports :: proc(doc: ^LDtkDoc) -> string {
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	folder := LDtk_LevelFilesFolder(doc.files[0].path)
	simplified := Json_Bool(main, Json_Get(main, root, "simplifiedExport"))
	mode := Json_String(main, Json_Get(main, root, "imageExportMode"))
	if mode == "" do mode = "None"
	if simplified do mode = "LayersAndLevels"
	pngDir := joinPath(folder, "png", allocator = context.temp_allocator)
	simpleDir := joinPath(folder, "simplified", allocator = context.temp_allocator)
	if mode == "None" || simplified do _ = removeAll(pngDir)
	if !simplified do _ = removeAll(simpleDir)
	if mode == "None" {
		ldtkRemoveIfEmpty(folder)
		return ""
	}
	if simplified {
		_ = removeAll(simpleDir)
	} else {
		ldtkInitDir(pngDir, ".png")
	}
	withBg := Json_Bool(main, Json_Get(main, root, "exportLevelBg"), true)
	pattern := Json_String(main, Json_Get(main, root, "pngFilePattern"))
	if pattern == "" do pattern = LDtk_DefaultPngPattern(mode)
	problems := make([dynamic]string, context.temp_allocator)
	for _, w in doc.worlds do for level, idx in worldLevels(doc, w) {
		identifier, _ := LDtkDoc_LevelNames(doc, level)
		dir := pngDir
		if simplified {
			dir = joinPath(simpleDir, identifier, allocator = context.temp_allocator)
			_ = os.make_directory_all(dir)
		}
		if p := ldtkLevelPictures(doc, level, idx, dir, mode, simplified ? "%layer_name" : pattern, withBg, simplified); p != "" do append(&problems, p)
		if simplified do if p := ldtkSimplifiedData(doc, level, dir); p != "" do append(&problems, p)
	}
	return strings.join(problems[:], "; ", context.temp_allocator)
}

// A folder made, its files of one extension removed (ProjectSaver.initDir)
@(private="file")
ldtkInitDir :: proc(dir, ext: string) {
	_ = os.make_directory_all(dir)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for e in entries do if e.type != .Directory && strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ext) do _ = os.remove(e.fullpath)
}

// LDtk's project folder goes when nothing is left in it (ProjectSaver's Done)
@(private="file")
ldtkRemoveIfEmpty :: proc(dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err == nil && len(entries) == 0 do _ = os.remove(dir)
}

/*
A picture's file name (Project.getPngFileName): the pattern with %level_name, %world, %level_idx
(4 digits), %layer_name, %layer_idx (2 digits: its place among the layers that aren't entities').
*/
LDtk_PngFileName :: proc(doc: ^LDtkDoc, pattern: string, level, levelIndex, layerUid: int, suffix := "") -> string {
	main := LDtkDoc_Main(doc)
	identifier, _ := LDtkDoc_LevelNames(doc, level)
	world, _ := LDtkDoc_WorldNames(doc, doc.levels[level].world)
	layerName := ""
	layerIndex := 0
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		if Json_Int(main, Json_Get(main, d, "uid")) == layerUid {
			layerName = Json_String(main, Json_Get(main, d, "identifier"))
			break
		}
		if Json_String(main, Json_Get(main, d, "type")) != "Entities" do layerIndex += 1
	}
	p := pattern
	p, _ = strings.replace_all(p, "%level_name", identifier, context.temp_allocator)
	p, _ = strings.replace_all(p, "%world", world, context.temp_allocator)
	p, _ = strings.replace_all(p, "%level_idx", fmt.tprintf("%04d", levelIndex), context.temp_allocator)
	p, _ = strings.replace_all(p, "%layer_name", layerName, context.temp_allocator)
	p, _ = strings.replace_all(p, "%layer_idx", fmt.tprintf("%02d", layerIndex), context.temp_allocator)
	return suffix == "" ? p : fmt.tprintf("%s-%s", p, suffix)
}

// Writes an RGBA picture as a PNG
@(private="file")
writePng :: proc(path: string, pixels: []u8, w, h: int) -> string {
	if w <= 0 || h <= 0 do return ""
	if stbiw.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(w), i32(h), 4, raw_data(pixels), i32(w * 4)) == 0 do return fmt.tprintf("couldn't write %s", filepath.base(path))
	return ""
}

// A picture filled with a color
@(private="file")
fillPixels :: proc(pixels: []u8, color: int) {
	for i := 0; i < len(pixels); i += 4 {
		pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = u8(color >> 16), u8(color >> 8), u8(color), 255
	}
}

// A picture drawn over another (straight alpha), at an opacity
@(private="file")
overPixels :: proc(dst, src: []u8, alpha: f32) {
	for i := 0; i < len(dst); i += 4 {
		sa := f32(src[i + 3]) / 255 * alpha
		if sa <= 0 do continue
		da := f32(dst[i + 3]) / 255
		oa := sa + da * (1 - sa)
		for c in 0 ..< 3 {
			v := (f32(src[i + c]) * sa + f32(dst[i + c]) * da * (1 - sa)) / oa
			dst[i + c] = u8(clamp(v + 0.5, 0, 255))
		}
		dst[i + 3] = u8(clamp(oa * 255 + 0.5, 0, 255))
	}
}

/*
A level's pictures (LayerRender.createPngs / createBgPng, the modes' composites) into a folder.
*/
@(private="file")
ldtkLevelPictures :: proc(doc: ^LDtkDoc, level, levelIndex: int, dir, mode, pattern: string, withBg, simplified: bool) -> string {
	m, ok := LDtkLevel_Read(doc, "", level)
	if !ok do return "a level can't be read"
	defer LDtkLevel_Destroy(&m)
	main := LDtkDoc_Main(doc)
	identifier, _ := LDtkDoc_LevelNames(doc, level)
	bgColor, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, doc.levels[level].entry, "__bgColor")))
	w, h := m.pxWid, m.pxHei
	size := w * h * 4
	if size <= 0 do return ""
	path :: proc(dir, name: string) -> string { return joinPath(dir, fmt.tprintf("%s.png", name), allocator = context.temp_allocator) }
	background :: proc(doc: ^LDtkDoc, m: ^LDtkLevelModel, color: int, size: int) -> []u8 {
		px := make([]u8, size, context.temp_allocator)
		fillPixels(px, color)
		LevelPictures_Render(doc, m, -1, true, px)
		return px
	}
	if mode == "OneImagePerLevel" {
		px := withBg ? background(doc, &m, bgColor, size) : make([]u8, size, context.temp_allocator)
		#reverse for &l in m.layers {
			d := &m.defs[l.def]
			if d.kind == .Entities || (d.kind == .IntGrid && !LDtkLayerInfo_IsAuto(d)) do continue
			layer := make([]u8, size, context.temp_allocator)
			LevelPictures_Render(doc, &m, ldtkLayerIndex(&m, &l), false, layer)
			overPixels(px, layer, f32(d.displayOpacity))
		}
		first := len(m.defs) > 0 ? m.defs[0].uid : -1
		return writePng(path(dir, LDtk_PngFileName(doc, pattern, level, levelIndex, first)), px, w, h)
	}
	// One picture per layer (and per level for LayersAndLevels)
	if withBg {
		if p := writePng(path(dir, simplified ? "_bg" : fmt.tprintf("%s_bg", identifier)), background(doc, &m, bgColor, size), w, h); p != "" do return p
	}
	composite := make([]u8, size, context.temp_allocator)
	if withBg do fillPixels(composite, bgColor)
	#reverse for &l in m.layers {
		d := &m.defs[l.def]
		if d.kind == .Entities do continue
		if d.kind == .Tiles || LDtkLayerInfo_IsAuto(d) {
			layer := make([]u8, size, context.temp_allocator)
			LevelPictures_Render(doc, &m, ldtkLayerIndex(&m, &l), false, layer)
			// LDtk draws the layer at its opacity into its picture
			faded := make([]u8, size, context.temp_allocator)
			overPixels(faded, layer, f32(d.displayOpacity))
			if p := writePng(path(dir, LDtk_PngFileName(doc, pattern, level, levelIndex, d.uid)), faded, w, h); p != "" do return p
			overPixels(composite, faded, 1)
		}
		if d.kind == .IntGrid {
			// A pixel per cell, the values' colors
			px := make([]u8, l.cWid * l.cHei * 4, context.temp_allocator)
			for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
				v := LDtkLayer_IntGrid(&l, cx, cy)
				if v == 0 do continue
				info := LDtkLayerInfo_Value(d, v)
				if info == nil do continue
				i := (cx + cy * l.cWid) * 4
				px[i], px[i + 1], px[i + 2], px[i + 3] = u8(info.color >> 16), u8(info.color >> 8), u8(info.color), 255
			}
			if p := writePng(path(dir, LDtk_PngFileName(doc, pattern, level, levelIndex, d.uid, "int")), px, l.cWid, l.cHei); p != "" do return p
		}
	}
	if mode == "LayersAndLevels" {
		return writePng(path(dir, simplified ? "_composite" : identifier), composite, w, h)
	}
	return ""
}

// A layer's index in a level model's layers
@(private="file")
ldtkLayerIndex :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> int {
	for &x, i in m.layers do if &x == l do return i
	return -1
}

/*
A level's simplified data (Level.toSimplifiedJson: data.json in JsonPretty's Full layout, a CSV per
IntGrid layer: exporter/Csv.toString2D).
*/
@(private="file")
ldtkSimplifiedData :: proc(doc: ^LDtkDoc, level: int, dir: string) -> string {
	main := LDtkDoc_Main(doc)
	entry := doc.levels[level].entry
	identifier, iid := LDtkDoc_LevelNames(doc, level)
	// Fields by definition uid (LDtk's map of them iterates in uid order)
	fieldsOf :: proc(json: ^JsonDoc, owner: int) -> LDtkJV {
		items := slice.clone(Json_Items(json, Json_Get(json, owner, "fieldInstances")), context.temp_allocator)
		slice.sort_by(items, proc(a, b: int) -> bool { return a < b })
		Field :: struct { uid, node: int }
		fs := make([dynamic]Field, context.temp_allocator)
		for fi in items do append(&fs, Field{Json_Int(json, Json_Get(json, fi, "defUid")), fi})
		slice.sort_by(fs[:], proc(a, b: Field) -> bool { return a.uid < b.uid })
		pairs := make([dynamic]LDtkJPair, context.temp_allocator)
		for f in fs do append(&pairs, jpair(strings.clone(Json_String(json, Json_Get(json, f.node, "__identifier")), context.temp_allocator), ldtkJV(json, Json_Get(json, f.node, "__value"))))
		return LDtkJObject(pairs[:])
	}
	// The pictures, bottom first: tiles, auto-layers (IntGrid layers only with rules)
	file, array := LDtkDoc_LayerInstances(doc, level)
	json := LDtkDoc_Json(doc, file)
	instances := Json_Items(json, array)
	layers := make([dynamic]LDtkJV, context.temp_allocator)
	#reverse for li in instances {
		t := Json_String(json, Json_Get(json, li, "__type"))
		def := LDtkDoc_DefByUid(doc, "layers", Json_Int(json, Json_Get(json, li, "layerDefUid")))
		auto := t == "AutoLayer" || (t == "IntGrid" && Json_Kind(main, Json_Get(main, def, "tilesetDefUid")) == .Number)
		if t == "Tiles" || auto do append(&layers, fmt.tprintf("%s.png", Json_String(json, Json_Get(json, li, "__identifier"))))
	}
	// Entities grouped by type, in the order they're met
	order := make([dynamic]string, context.temp_allocator)
	groups := make(map[string][dynamic]LDtkJV, context.temp_allocator)
	for li in instances {
		if Json_String(json, Json_Get(json, li, "__type")) != "Entities" do continue
		layerName := strings.clone(Json_String(json, Json_Get(json, li, "__identifier")), context.temp_allocator)
		for e in Json_Items(json, Json_Get(json, li, "entityInstances")) {
			id := strings.clone(Json_String(json, Json_Get(json, e, "__identifier")), context.temp_allocator)
			if id not_in groups {
				groups[id] = make([dynamic]LDtkJV, context.temp_allocator)
				append(&order, id)
			}
			px := Json_Get(json, e, "px")
			color, _ := LDtk_ParseColor(Json_String(json, Json_Get(json, e, "__smartColor")))
			list := &groups[id]
			append(list, jobject(
				jpair("id", id),
				jpair("iid", strings.clone(Json_String(json, Json_Get(json, e, "iid")), context.temp_allocator)),
				jpair("layer", layerName),
				jpair("x", i64(Json_Int(json, Json_At(json, px, 0)))),
				jpair("y", i64(Json_Int(json, Json_At(json, px, 1)))),
				jpair("width", i64(Json_Int(json, Json_Get(json, e, "width")))),
				jpair("height", i64(Json_Int(json, Json_Get(json, e, "height")))),
				jpair("color", i64(color)),
				jpair("customFields", fieldsOf(json, e)),
			))
		}
	}
	entities := make([dynamic]LDtkJPair, context.temp_allocator)
	for id in order do append(&entities, jpair(id, LDtkJArray(groups[id][:])))
	data := jobject(
		jpair("identifier", strings.clone(identifier, context.temp_allocator)),
		jpair("uniqueIdentifer", strings.clone(iid, context.temp_allocator)),
		jpair("x", i64(Json_Int(main, Json_Get(main, entry, "worldX")))),
		jpair("y", i64(Json_Int(main, Json_Get(main, entry, "worldY")))),
		jpair("width", i64(Json_Int(main, Json_Get(main, entry, "pxWid")))),
		jpair("height", i64(Json_Int(main, Json_Get(main, entry, "pxHei")))),
		jpair("bgColor", strings.clone(Json_String(main, Json_Get(main, entry, "__bgColor")), context.temp_allocator)),
		jpair("neighbourLevels", ldtkJV(main, Json_Get(main, entry, "__neighbours"))),
		jpair("customFields", fieldsOf(main, entry)),
		jpair("layers", LDtkJArray(layers[:])),
		jpair("entities", LDtkJObject(entities[:])),
	)
	if err := os.write_entire_file(joinPath(dir, "data.json", allocator = context.temp_allocator), transmute([]u8)LDtk_PrettyJsonFull(data)); err != nil do return fmt.tprintf("couldn't write %s's data.json", identifier)
	// IntGrid layers as CSV (one byte a cell, as LDtk's Csv keeps them)
	for li in instances {
		if Json_String(json, Json_Get(json, li, "__type")) != "IntGrid" do continue
		w, h := Json_Int(json, Json_Get(json, li, "__cWid")), Json_Int(json, Json_Get(json, li, "__cHei"))
		cells := Json_Items(json, Json_Get(json, li, "intGridCsv"))
		b := strings.builder_make(context.temp_allocator)
		for cy in 0 ..< h {
			for cx in 0 ..< w {
				i := cx + cy * w
				v := i < len(cells) ? Json_Int(json, cells[i]) & 0xFF : 0
				if cx > 0 do strings.write_byte(&b, ',')
				strings.write_int(&b, v)
			}
			if cy < h - 1 do strings.write_byte(&b, ',')
			strings.write_byte(&b, '\n')
		}
		name := fmt.tprintf("%s.csv", Json_String(json, Json_Get(json, li, "__identifier")))
		if err := os.write_entire_file(joinPath(dir, name, allocator = context.temp_allocator), transmute([]u8)strings.to_string(b)); err != nil do return fmt.tprintf("couldn't write %s", name)
	}
	return ""
}
