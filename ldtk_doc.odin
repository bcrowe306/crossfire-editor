package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

/*
An LDtk project as the LDtk tab edits it: its files' JSON, kept as written (ldtk_json.odin), with
where its worlds, levels, layers and entities are. ldtk_ops.odin's edits change it and write it
back (`LDtkDoc_Commit`).

- **Files:** the `.ldtk` file, then every level saved apart ("Save levels to separate files": a
  level's `externalRelPath`, a `.ldtkl` file beside the project). A level's own settings
  (identifier, world position, fields, neighbours) are in both its entry in the project file and
  its `.ldtkl` file; its layers only in the `.ldtkl` file (`LDtkDoc_LevelObjects`).
- **Worlds:** without LDtk's "Multi-worlds" option a project has one world, the file's root (its
  `levels`, `worldLayout`, `worldGridWidth`...); with it, every object of `worlds`.
- **Cached** per full path (`LDtkDoc_Get`), read again when a file's modification time changes.
  A change the editor didn't write (LDtk saved the file) is remembered (`LDtkDoc_Outside`), for the
  Level mode's status line.
- **Writing** (`LDtkDoc_Commit`) applies an edit's patches to each file, checks the result parses,
  and replaces the file atomically (a new file beside it, then renamed over it: a failure never
  leaves a half-written file). The new modification time is always later than the old one
  (`ensureNewerTime`), so every cache keyed by it (the inspector's, the viewport's, a running
  game's LDtk_WatchFiles) reads it again, even when the file system's clock is coarse.
*/

// One file of an LDtk project
LDtkDocFile :: struct {
	// The file (full path, owned)
	path: string,
	json: JsonDoc,
	modified: time.Time,
}

// A world of an LDtk project
LDtkDocWorld :: struct {
	// The object holding its settings (`worldLayout`, `worldGridWidth`...): the root, or one of
	// `worlds`
	object: int,
	// Its `levels` array (in the project file)
	levels: int,
	// Its identifier and iid (a single world's: "World" and the root's `dummyWorldIid`; temp)
	identifier, iid: string,
}

// A level, wherever its data is
LDtkDocLevel :: struct {
	world: int,
	// Its entry in the project file's levels
	entry: int,
	// The file holding its layers (0: the project file) and the level object there
	file, node: int,
}

// An LDtk project's files and where things are in them
LDtkDoc :: struct {
	// The .ldtk file first, then the levels' .ldtkl files
	files: [dynamic]LDtkDocFile,
	worlds: [dynamic]LDtkDocWorld,
	levels: [dynamic]LDtkDocLevel,
	// What couldn't be read ("" when everything was)
	problem: string,
	// Bumped every time it's read or written
	version: int,
}

// The document's project file
LDtkDoc_Main :: proc(doc: ^LDtkDoc) -> ^JsonDoc {
	return &doc.files[0].json
}

// When a file of a document was last changed outside the editor
LDtkOutsideChange :: struct {
	at: time.Time,
	// The changed file's name (owned)
	file: string,
}

@(private="file")
LDtkDocEntry :: struct {
	doc: ^LDtkDoc,
}

// Documents by the .ldtk file's full path. Package state, like the inspector's parsed copies
// (LDtkEdit_Project): the view reads them and they're a cache of the files. Thread-local: unit
// tests run on several threads
@(private="file", thread_local)
ldtkDocs: map[string]LDtkDocEntry
@(private="file", thread_local)
ldtkOutside: map[string]LDtkOutsideChange

/*
The LDtk project at a path, read (or read again, when one of its files changed since).

Inputs:
- root: The project folder
- path: The .ldtk file, relative to it

Returns:
- The document (owned by the cache; valid until the next call for that file), nil when the file
  can't be read at all (`problem` says why when it can be read but not understood)
*/
LDtkDoc_Get :: proc(root, path: string) -> ^LDtkDoc {
	if path == "" do return nil
	full := joinPath(root, path, allocator = context.temp_allocator)
	if entry, found := ldtkDocs[full]; found {
		if !ldtkDocChanged(entry.doc) do return entry.doc
		// Changed outside the editor (its own writes keep the times)
		changed := ""
		for f in entry.doc.files do if ldtkModified(f.path) != f.modified do changed = f.path
		if changed != "" {
			if old, had := ldtkOutside[full]; had do delete(old.file)
			else do ldtkOutside[strings.clone(full)] = {}
			ldtkOutside[full] = {time.now(), strings.clone(filepath.base(changed))}
		}
		version := entry.doc.version
		ldtkDocFree(entry.doc)
		entry.doc^ = ldtkDocRead(full)
		entry.doc.version = version + 1
		return entry.doc
	}
	if !os.exists(full) do return nil
	doc := new(LDtkDoc)
	doc^ = ldtkDocRead(full)
	ldtkDocs[strings.clone(full)] = {doc}
	return doc
}

/*
When an LDtk project's files last changed outside the editor (LDtk saved them), since the editor
read them first.

Returns:
- When and which file, and false if they never did
*/
LDtkDoc_Outside :: proc(root, path: string) -> (LDtkOutsideChange, bool) {
	full := joinPath(root, path, allocator = context.temp_allocator)
	change, found := ldtkOutside[full]
	return change, found
}

// Forgets that a project's files changed outside (the status line was read)
LDtkDoc_ForgetOutside :: proc(root, path: string) {
	full := joinPath(root, path, allocator = context.temp_allocator)
	if key, change := delete_key(&ldtkOutside, full); key != "" {
		delete(key)
		delete(change.file)
	}
}

// Frees every cached document (tests, quitting)
LDtkDoc_DestroyAll :: proc() {
	for path, entry in ldtkDocs {
		ldtkDocFree(entry.doc)
		free(entry.doc)
		delete(path)
	}
	delete(ldtkDocs)
	ldtkDocs = nil
	for path, change in ldtkOutside {
		delete(path)
		delete(change.file)
	}
	delete(ldtkOutside)
	ldtkOutside = nil
}

// Whether any of a document's files changed on disk since it was read or written
@(private="file")
ldtkDocChanged :: proc(doc: ^LDtkDoc) -> bool {
	if len(doc.files) == 0 do return true
	for f in doc.files do if ldtkModified(f.path) != f.modified do return true
	return false
}

@(private="file")
ldtkDocFree :: proc(doc: ^LDtkDoc) {
	for &f in doc.files {
		delete(f.path)
		Json_Destroy(&f.json)
	}
	delete(doc.files)
	delete(doc.worlds)
	delete(doc.levels)
	delete(doc.problem)
	doc^ = {}
}

// Reads a project's files and finds its worlds and levels
@(private="file")
ldtkDocRead :: proc(full: string) -> LDtkDoc {
	modified := ldtkModified(full)
	text, err := os.read_entire_file(full, context.temp_allocator)
	if err != nil do return LDtkDoc{problem = fmt.aprintf("Couldn't read %s: %v", filepath.base(full), err)}
	return ldtkDocBuild(full, string(text), modified, nil)
}

/*
A document made from texts in memory: the project file's, and the level files' in `texts` (by
full path; the others are read from disk). An edit's second pass reads what the first wrote
before anything is written (ldtk_ops.odin).
*/
LDtkDoc_FromTexts :: proc(doc: ^LDtkDoc, texts: []string) -> LDtkDoc {
	byPath := make(map[string]string, len(texts), context.temp_allocator)
	for f, i in doc.files do byPath[f.path] = texts[i]
	result := ldtkDocBuild(doc.files[0].path, texts[0], doc.files[0].modified, byPath)
	for &f in result.files do for old in doc.files do if old.path == f.path do f.modified = old.modified
	return result
}

// Frees a document made by LDtkDoc_FromTexts
LDtkDoc_Free :: proc(doc: ^LDtkDoc) {
	ldtkDocFree(doc)
}

@(private="file")
ldtkDocBuild :: proc(full, text: string, modified: time.Time, texts: map[string]string) -> LDtkDoc {
	doc := LDtkDoc{}
	json, problem := Json_Parse(text)
	if problem != "" {
		doc.problem = fmt.aprintf("%s isn't JSON: %s", filepath.base(full), problem)
		return doc
	}
	append(&doc.files, LDtkDocFile{strings.clone(full), json, modified})
	main := LDtkDoc_Main(&doc)
	root := Json_Root(main)
	if Json_Kind(main, root) != .Object || Json_Get(main, root, "defs") < 0 {
		doc.problem = fmt.aprintf("%s isn't an LDtk project", filepath.base(full))
		return doc
	}
	// The worlds: the root's (one world) or Multi-worlds' list
	worlds := Json_Get(main, root, "worlds")
	if Json_Count(main, worlds) > 0 {
		for w in Json_Items(main, worlds) {
			append(&doc.worlds, LDtkDocWorld{object = w, levels = Json_Get(main, w, "levels")})
		}
	} else {
		append(&doc.worlds, LDtkDocWorld{object = root, levels = Json_Get(main, root, "levels")})
	}
	folder := filepath.dir(full)
	for &world, wi in doc.worlds {
		for entry in Json_Items(main, world.levels) {
			level := LDtkDocLevel{world = wi, entry = entry, file = 0, node = entry}
			external := Json_Get(main, entry, "externalRelPath")
			if Json_Kind(main, external) == .String {
				rel := Json_String(main, external)
				path := joinPath(folder, rel, allocator = context.temp_allocator)
				levelText: []byte
				readErr: os.Error
				if inMemory, found := texts[path]; found do levelText = transmute([]byte)inMemory
				else do levelText, readErr = os.read_entire_file(path, context.temp_allocator)
				if readErr != nil {
					if doc.problem == "" do doc.problem = fmt.aprintf("Couldn't read the level file %s: %v", rel, readErr)
				} else if levelJson, levelProblem := Json_Parse(string(levelText)); levelProblem != "" {
					if doc.problem == "" do doc.problem = fmt.aprintf("The level file %s isn't JSON: %s", rel, levelProblem)
				} else {
					append(&doc.files, LDtkDocFile{strings.clone(path), levelJson, ldtkModified(path)})
					level.file = len(doc.files) - 1
					level.node = Json_Root(&doc.files[level.file].json)
				}
			}
			append(&doc.levels, level)
		}
	}
	return doc
}

// A world's identifier and iid (a single world: "World" and the root's dummyWorldIid)
LDtkDoc_WorldNames :: proc(doc: ^LDtkDoc, world: int) -> (identifier, iid: string) {
	main := LDtkDoc_Main(doc)
	w := doc.worlds[world]
	if w.object == Json_Root(main) do return "World", Json_String(main, Json_Get(main, w.object, "dummyWorldIid"))
	return Json_String(main, Json_Get(main, w.object, "identifier")), Json_String(main, Json_Get(main, w.object, "iid"))
}

// A file of the document's JSON
LDtkDoc_Json :: proc(doc: ^LDtkDoc, file: int) -> ^JsonDoc {
	return &doc.files[file].json
}

// A level's identifier and iid (pointing into the document)
LDtkDoc_LevelNames :: proc(doc: ^LDtkDoc, level: int) -> (identifier, iid: string) {
	main := LDtkDoc_Main(doc)
	entry := doc.levels[level].entry
	return Json_String(main, Json_Get(main, entry, "identifier")), Json_String(main, Json_Get(main, entry, "iid"))
}

// The level with an identifier or iid (-1 when there's none)
LDtkDoc_FindLevel :: proc(doc: ^LDtkDoc, name: string) -> int {
	for _, i in doc.levels {
		identifier, iid := LDtkDoc_LevelNames(doc, i)
		if identifier == name || iid == name do return i
	}
	return -1
}

// Where a level's settings are: its entry in the project file, and its .ldtkl file's object
LDtkDocPlace :: struct {
	file, node: int,
}

// Every copy of a level's own settings (temp allocated): its project file entry, then its .ldtkl object
LDtkDoc_LevelObjects :: proc(doc: ^LDtkDoc, level: int) -> []LDtkDocPlace {
	l := doc.levels[level]
	out := make([dynamic]LDtkDocPlace, context.temp_allocator)
	append(&out, LDtkDocPlace{0, l.entry})
	if l.file != 0 do append(&out, LDtkDocPlace{l.file, l.node})
	return out[:]
}

// A level's world rectangle {x, y, w, h} as LDtk lays it out (linear layouts: computed, 48 px apart)
LDtkDoc_LevelRect :: proc(doc: ^LDtkDoc, level: int) -> [4]f64 {
	main := LDtkDoc_Main(doc)
	l := doc.levels[level]
	w := Json_Float(main, Json_Get(main, l.entry, "pxWid"))
	h := Json_Float(main, Json_Get(main, l.entry, "pxHei"))
	layout := LDtkDoc_WorldLayout(doc, l.world)
	if layout == "LinearHorizontal" || layout == "LinearVertical" {
		at: f64 = 0
		for other, i in doc.levels {
			if other.world != l.world do continue
			if i == level do break
			at += (layout == "LinearHorizontal" ? Json_Float(main, Json_Get(main, other.entry, "pxWid")) : Json_Float(main, Json_Get(main, other.entry, "pxHei"))) + LDTK_LINEAR_SPACING
		}
		return layout == "LinearHorizontal" ? {at, 0, w, h} : {0, at, w, h}
	}
	return {Json_Float(main, Json_Get(main, l.entry, "worldX")), Json_Float(main, Json_Get(main, l.entry, "worldY")), w, h}
}

// LDtk's gap between levels in linear world layouts (World.reorganizeWorld)
LDTK_LINEAR_SPACING :: 48

// A world's layout ("Free", "GridVania", "LinearHorizontal", "LinearVertical")
LDtkDoc_WorldLayout :: proc(doc: ^LDtkDoc, world: int) -> string {
	main := LDtkDoc_Main(doc)
	layout := Json_String(main, Json_Get(main, doc.worlds[world].object, "worldLayout"))
	return layout == "" ? "Free" : layout
}

// A world's grid size (GridVania's cells)
LDtkDoc_WorldGrid :: proc(doc: ^LDtkDoc, world: int) -> [2]int {
	main := LDtkDoc_Main(doc)
	o := doc.worlds[world].object
	return {max(Json_Int(main, Json_Get(main, o, "worldGridWidth"), 256), 1), max(Json_Int(main, Json_Get(main, o, "worldGridHeight"), 256), 1)}
}

// The project file's `defs` and one of its lists ("layers", "entities", "enums", "tilesets", "levelFields")
LDtkDoc_Defs :: proc(doc: ^LDtkDoc, list: string) -> int {
	main := LDtkDoc_Main(doc)
	return Json_Get(main, Json_Get(main, Json_Root(main), "defs"), list)
}

// A definition by uid in one of `defs`' lists (-1 when there's none)
LDtkDoc_DefByUid :: proc(doc: ^LDtkDoc, list: string, uid: int) -> int {
	main := LDtkDoc_Main(doc)
	for d in Json_Items(main, LDtkDoc_Defs(doc, list)) do if Json_Int(main, Json_Get(main, d, "uid"), -1) == uid do return d
	return -1
}

// A level's layer instances array (in its file), or -1 (an external level not read)
LDtkDoc_LayerInstances :: proc(doc: ^LDtkDoc, level: int) -> (file, array: int) {
	l := doc.levels[level]
	json := LDtkDoc_Json(doc, l.file)
	array = Json_Get(json, l.node, "layerInstances")
	if Json_Kind(json, array) != .Array do return l.file, -1
	return l.file, array
}

// An entity instance found by iid: where it is
LDtkDocEntity :: struct {
	level, file: int,
	// The layer instance and the entity's object
	layer, node: int,
}

// Every entity instance of the project, levels and layers in order (temp allocated)
LDtkDoc_Entities :: proc(doc: ^LDtkDoc) -> []LDtkDocEntity {
	out := make([dynamic]LDtkDocEntity, context.temp_allocator)
	for _, level in doc.levels {
		file, layers := LDtkDoc_LayerInstances(doc, level)
		if layers < 0 do continue
		json := LDtkDoc_Json(doc, file)
		for layer in Json_Items(json, layers) {
			for e in Json_Items(json, Json_Get(json, layer, "entityInstances")) do append(&out, LDtkDocEntity{level, file, layer, e})
		}
	}
	return out[:]
}

// An entity instance by iid (false when there's none)
LDtkDoc_FindEntity :: proc(doc: ^LDtkDoc, iid: string) -> (LDtkDocEntity, bool) {
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		if Json_String(json, Json_Get(json, e.node, "iid")) == iid do return e, true
	}
	return {}, false
}

// An edit's patches, per file of the document (temp allocated: an edit lives for the frame)
LDtkPatches :: struct {
	files: [dynamic][dynamic]JsonPatch,
}

// Adds a patch to an edit
LDtkPatches_Add :: proc(p: ^LDtkPatches, file: int, patch: JsonPatch) {
	if p.files == nil do p.files = make([dynamic][dynamic]JsonPatch, context.temp_allocator)
	for len(p.files) <= file do append(&p.files, make([dynamic]JsonPatch, context.temp_allocator))
	append(&p.files[file], patch)
}

// Adds a patch replacing a node's value (nothing when the node is missing)
LDtkPatches_Set :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, node: int, text: string) {
	if node < 0 do return
	json := LDtkDoc_Json(doc, file)
	if Json_Text(json, node) == text do return
	LDtkPatches_Add(p, file, Json_SetPatch(json, node, text))
}

// Whether an edit has any patch
LDtkPatches_Empty :: proc(p: ^LDtkPatches) -> bool {
	for f in p.files do if len(f) > 0 do return false
	return true
}

/*
Applies an edit's patches and writes the files it changed (each replaced atomically), then reads
the document again from what was written.

Returns:
- "" or what went wrong (then no file was written: the patches overlapped, or a result didn't parse)
*/
LDtkDoc_Commit :: proc(doc: ^LDtkDoc, patches: ^LDtkPatches) -> string {
	texts := LDtkDoc_Texts(doc)
	if problem := LDtkDoc_Apply(doc, texts, patches); problem != "" do return problem
	return LDtkDoc_WriteTexts(doc, texts)
}

// The texts a document holds, one per file (temp allocated; they point into the document)
LDtkDoc_Texts :: proc(doc: ^LDtkDoc) -> []string {
	texts := make([]string, len(doc.files), context.temp_allocator)
	for f, i in doc.files do texts[i] = f.json.text
	return texts
}

/*
Applies an edit's patches to texts of a document's files (in place; the new texts are temp
allocated), checking each result still parses.

Inputs:
- texts: A text per file (`LDtkDoc_Texts`), whose spans the patches refer to

Returns:
- "" or what went wrong (then `texts` may be partly changed: don't write them)
*/
LDtkDoc_Apply :: proc(doc: ^LDtkDoc, texts: []string, patches: ^LDtkPatches) -> string {
	for list, i in patches.files {
		if len(list) == 0 || i >= len(texts) do continue
		text, ok := Json_Apply(texts[i], list[:], context.temp_allocator)
		if !ok do return "the edit's changes overlap (nothing was written)"
		check, problem := Json_Parse(text, context.temp_allocator)
		if problem != "" do return fmt.tprintf("the edit made %s unreadable (nothing was written): %s", filepath.base(doc.files[i].path), problem)
		Json_Destroy(&check)
		texts[i] = text
	}
	return ""
}

/*
Writes new texts for a document's files (those that differ from what it holds), atomically, and
reads it again. Undo and redo write a step's files back through it.

Inputs:
- texts: A text per file of the document, in its order

Returns:
- "" or what went wrong
*/
LDtkDoc_WriteTexts :: proc(doc: ^LDtkDoc, texts: []string) -> string {
	full := strings.clone(doc.files[0].path, context.temp_allocator)
	for text, i in texts {
		if i >= len(doc.files) || text == doc.files[i].json.text do continue
		if problem := LDtk_WriteFile(doc.files[i].path, text, doc.files[i].modified); problem != "" do return problem
	}
	version := doc.version
	ldtkDocFree(doc)
	doc^ = ldtkDocRead(full)
	doc.version = version + 1
	return ""
}

/*
Replaces a file's text atomically: the text is written to a new file beside it, which is then
renamed over it. The file's modification time ends up later than `before` (the time the editor
last saw), so caches keyed by it notice the change.

Returns:
- "" or what went wrong (the file is then as it was)
*/
LDtk_WriteFile :: proc(path, text: string, before: time.Time) -> string {
	temp := fmt.tprintf("%s.crossfire-tmp", path)
	if err := os.write_entire_file(temp, transmute([]byte)text); err != nil {
		os.remove(temp)
		return fmt.tprintf("Couldn't write %s: %v", filepath.base(path), err)
	}
	if err := os.rename(temp, path); err != nil {
		os.remove(temp)
		return fmt.tprintf("Couldn't replace %s: %v", filepath.base(path), err)
	}
	ensureNewerTime(path, before)
	return ""
}

// Moves a written file's modification time past `before` when the clock didn't (a coarse file
// system clock gives two writes within a few milliseconds the same time)
@(private="file")
ensureNewerTime :: proc(path: string, before: time.Time) {
	now := ldtkModified(path)
	if time.diff(before, now) > 0 do return
	later := time.time_add(before, time.Millisecond)
	_ = os.change_times(path, later, later)
}

/*
The texts of a document's files, read from disk now (temp allocated; "" for a file that can't be
read). Undo snapshots take them.
*/
LDtkDoc_DiskTexts :: proc(doc: ^LDtkDoc) -> []string {
	out := make([]string, len(doc.files), context.temp_allocator)
	for f, i in doc.files {
		data, err := os.read_entire_file(f.path, context.temp_allocator)
		out[i] = err == nil ? string(data) : ""
	}
	return out
}

// The document's folder (the .ldtk file's)
LDtkDoc_Folder :: proc(doc: ^LDtkDoc) -> string {
	return filepath.dir(doc.files[0].path)
}
