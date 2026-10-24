package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import e "engine:."

/*
An LDtk project as the Level mode edits it: its files' JSON, kept as written (ldtk_json.odin), with
where its worlds, levels, layers and entities are. ldtk_ops.odin's edits change it.

- **Files:** the `.ldtk` file, then every level saved apart ("Save levels to separate files": a
  level's `externalRelPath`, a `.ldtkl` file beside the project). A level's own settings
  (identifier, world position, fields, neighbours) are in both its entry in the project file and
  its `.ldtkl` file; its layers only in the `.ldtkl` file (`LDtkDoc_LevelObjects`).
- **Worlds:** without LDtk's "Multi-worlds" option a project has one world, the file's root (its
  `levels`, `worldLayout`, `worldGridWidth`...); with it, every object of `worlds`.
- **Edits stay in memory** (decided 2026-10-24, as LDtk does: fast painting, an undo step per
  stroke): an edit changes the document's texts (`LDtkDoc_Commit`), not the files. Each file
  remembers what's on disk (`saved`, its time `modified`), so the document knows it's unsaved
  (`LDtkDoc_Unsaved`); Save (Ctrl+S), Play and exports write it (`LDtkDoc_Save`,
  `LDtkDocs_SaveProject`), each file replaced atomically. Until then the project shows
  "Modified", and the viewport, the inspector and the Level mode's pictures read the document
  in memory (`LDtkDoc_Stamp`, `LDtkDoc_ProvideToGame`, `LDtkDoc_GameText`).
- **Cached** per full path (`LDtkDoc_Get`), read again when a file's modification time changes.
  A change the editor didn't write (LDtk saved the file) is remembered (`LDtkDoc_Outside`), for the
  Level mode's status line. With unsaved edits, LDtk's change is merged into them when the two
  don't touch (`History_MergeText`: base the saved text, ours the document's, theirs the file's);
  otherwise the file's new text waits (`LDtkDoc_DiskConflict`) until the user reloads it (the
  unsaved edits dropped) or keeps the editor's (Save then writes over LDtk's change):
  `LDtkDoc_ResolveDisk`.
- **Writing** (`LDtkDoc_Save`) replaces each changed file atomically (a new file beside it, then
  renamed over it: a failure never leaves a half-written file). The new modification time is
  always later than the old one (`ensureNewerTime`), so every cache keyed by it (the inspector's,
  the viewport's, a running game's LDtk_WatchFiles) reads it again, even when the file system's
  clock is coarse.
*/

// One file of an LDtk project
LDtkDocFile :: struct {
	// The file (full path, owned)
	path: string,
	// What the editor has: the text on disk, or with the edits not saved yet
	json: JsonDoc,
	// The file on disk as last read or written: its modification time and text (owned)
	modified: time.Time,
	saved: string,
	// The editor's text isn't what's on disk (`json.text != saved`)
	unsaved: bool,
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

// A file's new text on disk, waiting while it clashes with unsaved edits (owned)
LDtkDiskText :: struct {
	path, text: string,
	modified: time.Time,
}

// An LDtk project's files and where things are in them
LDtkDoc :: struct {
	// The .ldtk file first, then the levels' .ldtkl files
	files: [dynamic]LDtkDocFile,
	worlds: [dynamic]LDtkDocWorld,
	levels: [dynamic]LDtkDocLevel,
	// What couldn't be read ("" when everything was)
	problem: string,
	// Bumped every time it's read, edited or written
	version: int,
	// Files LDtk changed while the editor had unsaved edits in them that touch the same places:
	// their texts on disk, until `LDtkDoc_ResolveDisk` (empty: none)
	diskConflict: [dynamic]LDtkDiskText,
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
	// The editor had unsaved edits: they were merged with it (`merged`), or they clash with it
	// (`conflict`: LDtkDoc_DiskConflict)
	merged, conflict: bool,
}

@(private="file")
LDtkDocEntry :: struct {
	doc: ^LDtkDoc,
}

// Documents by the .ldtk file's full path. Package state, like the inspector's parsed copies
// (LDtkEdit_Project): the view reads them. Thread-local: unit tests run on several threads
@(private="file", thread_local)
ldtkDocs: map[string]LDtkDocEntry
@(private="file", thread_local)
ldtkOutside: map[string]LDtkOutsideChange

/*
The LDtk project at a path, read (or read again, when one of its files changed on disk since). A
change on disk while the document has unsaved edits is merged into them when the two don't touch;
when they do, the document stays as it is and the disk's text waits (`LDtkDoc_DiskConflict`).

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
		doc := entry.doc
		if !ldtkDocChanged(doc) do return doc
		// Changed outside the editor (its own writes keep the times)
		changed := ""
		for f in doc.files do if ldtkModified(f.path) != f.modified do changed = f.path
		if changed == "" && len(doc.files) == 0 do changed = full
		if !LDtkDoc_Unsaved(doc) {
			ldtkNoteOutside(full, changed, false, false)
			version := doc.version
			ldtkDocFree(doc)
			doc^ = ldtkDocRead(full)
			doc.version = version + 1
			return doc
		}
		// Unsaved edits: LDtk's change merged into them, or waiting for the user
		if len(doc.diskConflict) > 0 && ldtkConflictSeen(doc) do return doc
		merged := ldtkMergeDisk(doc)
		ldtkNoteOutside(full, changed, merged, !merged)
		return doc
	}
	if !os.exists(full) do return nil
	doc := new(LDtkDoc)
	doc^ = ldtkDocRead(full)
	ldtkDocs[strings.clone(full)] = {doc}
	return doc
}

// The document at a path if it's cached (nil: never read, so not edited either)
@(private="file")
ldtkCached :: proc(root, path: string) -> ^LDtkDoc {
	if path == "" do return nil
	full := joinPath(root, path, allocator = context.temp_allocator)
	if entry, found := ldtkDocs[full]; found do return entry.doc
	return nil
}

@(private="file")
ldtkNoteOutside :: proc(full, changed: string, merged, conflict: bool) {
	if old, had := ldtkOutside[full]; had do delete(old.file)
	else do ldtkOutside[strings.clone(full)] = {}
	ldtkOutside[full] = {time.now(), strings.clone(filepath.base(changed)), merged, conflict}
}

// Whether the waiting disk texts are still what's on disk (nothing newer to merge)
@(private="file")
ldtkConflictSeen :: proc(doc: ^LDtkDoc) -> bool {
	for f in doc.files {
		now := ldtkModified(f.path)
		if now == f.modified do continue
		seen := false
		for d in doc.diskConflict do if d.path == f.path && d.modified == now do seen = true
		if !seen do return false
	}
	return true
}

/*
Merges what changed on disk into a document with unsaved edits: per file, the editor's change
(from the saved text to its own) and the disk's (from the saved text to the file's) when they
don't touch. A file without unsaved edits simply takes the disk's text; with `keepMine`, a file
whose changes clash keeps the editor's text (Save writes it over the disk's).

Returns:
- Whether everything merged (false: the document is as it was, the disk's texts wait in
  `diskConflict`)
*/
@(private="file")
ldtkMergeDisk :: proc(doc: ^LDtkDoc, keepMine := false) -> bool {
	clearDiskConflict(doc)
	texts := make(map[string]string, len(doc.files), context.temp_allocator)
	disk := make([]string, len(doc.files), context.temp_allocator)
	times := make([]time.Time, len(doc.files), context.temp_allocator)
	clash := false
	for f, i in doc.files {
		times[i] = ldtkModified(f.path)
		data, err := os.read_entire_file(f.path, context.temp_allocator)
		disk[i] = err == nil ? string(data) : f.saved
		switch {
		case disk[i] == f.saved:
			texts[f.path] = f.json.text
		case !f.unsaved || disk[i] == f.json.text:
			texts[f.path] = disk[i]
		case:
			merged, ok := History_MergeText(f.saved, f.json.text, disk[i])
			if ok {
				texts[f.path] = merged
			} else if keepMine {
				texts[f.path] = f.json.text
			} else {
				clash = true
				append(&doc.diskConflict, LDtkDiskText{strings.clone(f.path), strings.clone(disk[i]), times[i]})
			}
		}
	}
	if clash do return false
	paths := make([]string, len(doc.files), context.temp_allocator)
	for f, i in doc.files do paths[i] = strings.clone(f.path, context.temp_allocator)
	full := paths[0]
	next := ldtkDocBuild(full, texts, doc)
	// What's on disk now is the saved text the merged edits are measured from
	for &f in next.files {
		for p, i in paths do if p == f.path {
			delete(f.saved)
			f.saved = strings.clone(disk[i])
			f.modified = times[i]
		}
		f.unsaved = f.json.text != f.saved
	}
	version := doc.version
	ldtkDocFree(doc)
	doc^ = next
	doc.version = version + 1
	return true
}

@(private="file")
clearDiskConflict :: proc(doc: ^LDtkDoc) {
	for d in doc.diskConflict {
		delete(d.path)
		delete(d.text)
	}
	delete(doc.diskConflict)
	doc.diskConflict = nil
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

/*
Whether a document's files changed on disk in a way that clashes with its unsaved edits (LDtk
saved over the same places): the user reloads the files or keeps the editor's version
(`LDtkDoc_ResolveDisk`).

Returns:
- The changed files' names (temp allocated), and whether there are any
*/
LDtkDoc_DiskConflict :: proc(root, path: string) -> ([]string, bool) {
	doc := ldtkCached(root, path)
	if doc == nil || len(doc.diskConflict) == 0 do return nil, false
	names := make([]string, len(doc.diskConflict), context.temp_allocator)
	for d, i in doc.diskConflict do names[i] = filepath.base(d.path)
	return names, true
}

// Frees every cached document (tests, quitting, another project opened: unsaved edits are dropped)
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
		delete(f.saved)
		Json_Destroy(&f.json)
	}
	delete(doc.files)
	delete(doc.worlds)
	delete(doc.levels)
	delete(doc.problem)
	clearDiskConflict(doc)
	doc^ = {}
}

// Reads a project's files from disk and finds its worlds and levels
@(private="file")
ldtkDocRead :: proc(full: string) -> LDtkDoc {
	return ldtkDocBuild(full, nil, nil)
}

/*
A document made from texts in memory: the files' in `texts` (by full path; the others are read
from disk). Each file keeps the saved text and time `doc` has for it (a file `doc` doesn't have is
taken as it is on disk). An edit's second pass reads what the first made (ldtk_ops.odin).
*/
LDtkDoc_FromTexts :: proc(doc: ^LDtkDoc, texts: []string) -> LDtkDoc {
	byPath := make(map[string]string, len(texts), context.temp_allocator)
	for f, i in doc.files do if i < len(texts) do byPath[f.path] = texts[i]
	return ldtkDocBuild(doc.files[0].path, byPath, doc)
}

// Frees a document made by LDtkDoc_FromTexts
LDtkDoc_Free :: proc(doc: ^LDtkDoc) {
	ldtkDocFree(doc)
}

/*
Builds a document: the project file and its levels' files, from `texts` (by full path) or from
disk. A file `base` has keeps its saved text and time; another is as it is on disk.
*/
@(private="file")
ldtkDocBuild :: proc(full: string, texts: map[string]string, base: ^LDtkDoc) -> LDtkDoc {
	doc := LDtkDoc{}
	// A file's text (from `texts` or disk) and what's on disk for it (`base`'s, or the disk's)
	load :: proc(path: string, texts: map[string]string, base: ^LDtkDoc) -> (text, saved: string, modified: time.Time, err: os.Error) {
		if base != nil do for f in base.files do if f.path == path {
			saved, modified = f.saved, f.modified
			if t, found := texts[path]; found do return t, saved, modified, nil
			return f.json.text, saved, modified, nil
		}
		modified = ldtkModified(path)
		data, readErr := os.read_entire_file(path, context.temp_allocator)
		if t, found := texts[path]; found {
			return t, readErr == nil ? string(data) : t, modified, nil
		}
		if readErr != nil do return "", "", modified, readErr
		return string(data), string(data), modified, nil
	}
	text, saved, modified, err := load(full, texts, base)
	if err != nil {
		doc.problem = fmt.aprintf("Couldn't read %s: %v", filepath.base(full), err)
		return doc
	}
	json, problem := Json_Parse(text)
	if problem != "" {
		doc.problem = fmt.aprintf("%s isn't JSON: %s", filepath.base(full), problem)
		return doc
	}
	append(&doc.files, LDtkDocFile{path = strings.clone(full), json = json, modified = modified, saved = strings.clone(saved), unsaved = text != saved})
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
				levelText, levelSaved, levelModified, readErr := load(path, texts, base)
				if readErr != nil {
					if doc.problem == "" do doc.problem = fmt.aprintf("Couldn't read the level file %s: %v", rel, readErr)
				} else if levelJson, levelProblem := Json_Parse(levelText); levelProblem != "" {
					if doc.problem == "" do doc.problem = fmt.aprintf("The level file %s isn't JSON: %s", rel, levelProblem)
				} else {
					append(&doc.files, LDtkDocFile{path = strings.clone(path), json = levelJson, modified = levelModified, saved = strings.clone(levelSaved), unsaved = levelText != levelSaved})
					level.file = len(doc.files) - 1
					level.node = Json_Root(&doc.files[level.file].json)
				}
			}
			append(&doc.levels, level)
		}
	}
	return doc
}

/*
Answers a clash between unsaved edits and LDtk's change on disk (`LDtkDoc_DiskConflict`).

Inputs:
- reload: Read the files as they are on disk (the unsaved edits are dropped); false keeps the
  editor's version where the two clash (still unsaved: Save writes it over LDtk's change), and
  takes LDtk's changes elsewhere

Returns:
- What was done, for the Console ("" when there was nothing to answer; temp allocated)
*/
LDtkDoc_ResolveDisk :: proc(root, path: string, reload: bool) -> string {
	doc := ldtkCached(root, path)
	if doc == nil || len(doc.diskConflict) == 0 do return ""
	name := strings.clone(filepath.base(doc.files[0].path), context.temp_allocator)
	if reload {
		full := strings.clone(doc.files[0].path, context.temp_allocator)
		version := doc.version
		ldtkDocFree(doc)
		doc^ = ldtkDocRead(full)
		doc.version = version + 1
		return fmt.tprintf("Read %s again as LDtk saved it: the unsaved edits were dropped (Ctrl+Z still steps through them)", name)
	}
	ldtkMergeDisk(doc, keepMine = true)
	return fmt.tprintf("Kept your edits to %s: saving writes them over LDtk's change", name)
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
Applies an edit's patches to the document in memory (nothing is written: `LDtkDoc_Save` does,
on Save, Play and exports), and reads it again from the new texts.

Returns:
- "" or what went wrong (then nothing changed: the patches overlapped, or a result didn't parse)
*/
LDtkDoc_Commit :: proc(doc: ^LDtkDoc, patches: ^LDtkPatches) -> string {
	texts := LDtkDoc_Texts(doc)
	if problem := LDtkDoc_Apply(doc, texts, patches); problem != "" do return problem
	return LDtkDoc_SetTexts(doc, texts)
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
- "" or what went wrong (then `texts` may be partly changed: don't use them)
*/
LDtkDoc_Apply :: proc(doc: ^LDtkDoc, texts: []string, patches: ^LDtkPatches) -> string {
	for list, i in patches.files {
		if len(list) == 0 || i >= len(texts) do continue
		text, ok := Json_Apply(texts[i], list[:], context.temp_allocator)
		if !ok do return "the edit's changes overlap (nothing was changed)"
		check, problem := Json_Parse(text, context.temp_allocator)
		if problem != "" do return fmt.tprintf("the edit made %s unreadable (nothing was changed): %s", filepath.base(doc.files[i].path), problem)
		Json_Destroy(&check)
		texts[i] = text
	}
	return ""
}

/*
Gives a document new texts for its files, in memory (undo and redo put a step's texts back
through it), and reads it again from them. Each file keeps what's on disk, so it's unsaved when
its text differs from that.

Inputs:
- texts: A text per file of the document, in its order

Returns:
- "" or what went wrong (a text that isn't a readable LDtk project: the document is as it was)
*/
LDtkDoc_SetTexts :: proc(doc: ^LDtkDoc, texts: []string) -> string {
	same := true
	for text, i in texts do if i < len(doc.files) && text != doc.files[i].json.text do same = false
	if same do return ""
	next := LDtkDoc_FromTexts(doc, texts)
	if next.problem != "" {
		problem := fmt.tprintf("%s", next.problem)
		ldtkDocFree(&next)
		return problem
	}
	version := doc.version
	conflict := doc.diskConflict
	doc.diskConflict = nil
	ldtkDocFree(doc)
	doc^ = next
	doc.version = version + 1
	doc.diskConflict = conflict
	return ""
}

// The text a document has for one of its files, by full path (false: not one of its files)
LDtkDoc_TextOf :: proc(doc: ^LDtkDoc, path: string) -> (string, bool) {
	for f in doc.files do if f.path == path do return f.json.text, true
	return "", false
}

/*
The text the editor has for a file of any document it has read (an edited one's unsaved text), by
full path: tests and the UI driver read values through it.

Returns:
- The text, and false when no document has the file (read it from disk)
*/
LDtkDoc_CachedText :: proc(path: string) -> (string, bool) {
	for _, entry in ldtkDocs do if text, found := LDtkDoc_TextOf(entry.doc, path); found do return text, true
	return "", false
}

// Whether a document has edits not written to its files yet
LDtkDoc_Unsaved :: proc(doc: ^LDtkDoc) -> bool {
	if doc == nil do return false
	for f in doc.files do if f.unsaved do return true
	return false
}

// Whether an LDtk project (relative to the project folder) has unsaved edits in the editor
LDtkDoc_IsUnsaved :: proc(root, path: string) -> bool {
	return LDtkDoc_Unsaved(ldtkCached(root, path))
}

/*
Writes a document's unsaved files (each replaced atomically; the others aren't touched), first
merging what LDtk saved meanwhile (`LDtkDoc_Get`). Refused while LDtk's change clashes with the
edits (`LDtkDoc_DiskConflict`): the user answers that first.

Returns:
- "" or what went wrong (the files written before it stay written)
*/
LDtkDoc_Save :: proc(root, path: string) -> string {
	doc := ldtkCached(root, path)
	if doc == nil || !LDtkDoc_Unsaved(doc) do return ""
	// LDtk saved meanwhile: merged first (or a clash)
	doc = LDtkDoc_Get(root, path)
	if doc == nil do return fmt.tprintf("%s is gone", filepath.base(path))
	if len(doc.diskConflict) > 0 do return fmt.tprintf("%s changed outside the editor where your unsaved edits are: reload it or keep your edits first (the Level mode's bar)", filepath.base(path))
	for &f in doc.files {
		if !f.unsaved do continue
		if problem := LDtk_WriteFile(f.path, f.json.text, f.modified); problem != "" do return problem
		delete(f.saved)
		f.saved = strings.clone(f.json.text)
		f.modified = ldtkModified(f.path)
		f.unsaved = false
	}
	doc.version += 1
	return ""
}

/*
Writes every LDtk project of the editor's project that has unsaved edits (Save, Play, exports).

Returns:
- Whether all of them were written (each problem is logged)
*/
LDtkDocs_SaveProject :: proc(state: ^State) -> bool {
	ok := true
	for asset in state.project.assets {
		if asset.kind != .LDtk || !LDtkDoc_IsUnsaved(state.project.rootPath, asset.path) do continue
		if problem := LDtkDoc_Save(state.project.rootPath, asset.path); problem != "" {
			logLine(state, .Error, fmt.aprintf("Couldn't save %s: %s", asset.path, problem))
			ok = false
		} else {
			logLine(state, .Info, fmt.aprintf("Saved %s", asset.path))
		}
	}
	return ok
}

// Whether any LDtk project of the editor's project has unsaved edits
LDtkDocs_AnyUnsaved :: proc(state: ^State) -> bool {
	for asset in state.project.assets do if asset.kind == .LDtk && LDtkDoc_IsUnsaved(state.project.rootPath, asset.path) do return true
	return false
}

/*
The unsaved texts of a project's LDtk files, by full path (temp allocated): Save As writes them
into the copy, which then has the edits saved and the original stays as it was on disk.
*/
LDtkDocs_UnsavedTexts :: proc(state: ^State) -> map[string]string {
	out := make(map[string]string, 8, context.temp_allocator)
	for asset in state.project.assets {
		if asset.kind != .LDtk do continue
		doc := ldtkCached(state.project.rootPath, asset.path)
		if doc == nil do continue
		for f in doc.files do if f.unsaved do out[f.path] = f.json.text
	}
	return out
}

/*
A stamp of what an LDtk file reads as now: it changes when the file changes on disk and with every
unsaved edit. Caches of what the engine makes of the file key on it (the viewport, the inspector,
the Level mode's pictures).

Returns:
- The stamp
*/
LDtkDoc_Stamp :: proc(root, path: string) -> u64 {
	full := joinPath(root, path, allocator = context.temp_allocator)
	if doc := ldtkCached(root, path); doc != nil && LDtkDoc_Unsaved(doc) {
		return hash.fnv64a(transmute([]byte)fmt.tprintf("unsaved|%s|%d", full, doc.version))
	}
	return hash.fnv64a(transmute([]byte)fmt.tprintf("disk|%s|%v", full, ldtkModified(full)))
}

/*
The document as one project file the engine reads (`e.LDtk_Parse`): its levels saved apart get
their layers from their `.ldtkl` files' texts in memory (the engine reads a level entry's layers
when it has them, else its file from disk).

Returns:
- The text (temp allocated)
*/
LDtkDoc_GameText :: proc(doc: ^LDtkDoc) -> string {
	main := LDtkDoc_Main(doc)
	patches := make([dynamic]JsonPatch, context.temp_allocator)
	for level in doc.levels {
		if level.file == 0 do continue
		json := LDtkDoc_Json(doc, level.file)
		layers := Json_Get(json, level.node, "layerInstances")
		if layers < 0 do continue
		at := Json_Get(main, level.entry, "layerInstances")
		if at >= 0 {
			append(&patches, Json_SetPatch(main, at, Json_Text(json, layers)))
		} else {
			append(&patches, Json_AddMemberPatch(main, level.entry, "layerInstances", Json_Text(json, layers)))
		}
	}
	if len(patches) == 0 do return main.text
	text, ok := Json_Apply(main.text, patches[:], context.temp_allocator)
	return ok ? text : main.text
}

/*
Gives a game the editor's unsaved version of an LDtk project (parsed from `LDtkDoc_GameText`), so
`e.Game_LoadLDtk` finds it instead of reading the file; a saved one is left for the game to read.
Forget the game's copy first when the stamp changed (`LDtkDoc_Stamp`).

Returns:
- Whether the game got the unsaved version
*/
LDtkDoc_ProvideToGame :: proc(game: ^e.Game, root, path: string) -> bool {
	doc := ldtkCached(root, path)
	if game == nil || doc == nil || !LDtkDoc_Unsaved(doc) || doc.problem != "" do return false
	if path in game.ldtk do return true
	project, problem := e.LDtk_Parse(LDtkDoc_GameText(doc), doc.files[0].path)
	if project == nil {
		_ = problem
		return false
	}
	if game.ldtk == nil do game.ldtk = make(map[string]^e.LDtkProject)
	game.ldtk[strings.clone(path)] = project
	return true
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
	if err := File_Replace(temp, path, text); err != nil {
		os.remove(temp)
		return fmt.tprintf("Couldn't replace %s: %v", filepath.base(path), err)
	}
	ensureNewerTime(path, before)
	return ""
}

/*
Puts a new file (`temp`, holding `text`) in place of another: a rename over it, which replaces
it whole on every OS (Windows: `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`, what `os.rename`
does). On Windows a rename fails while another program has the file open without sharing its
deletion (LDtk, an indexer, a virus scanner looking at the new file), so it's tried again a few
times, then the text is written into the file itself (not atomic, but the edit isn't lost).

Inputs:
- temp: The new file, beside `path`
- path: The file to replace
- text: What `temp` holds (written into `path` when the rename can't be done)

Returns:
- nil, or the last error (then `path` is as it was)
*/
File_Replace :: proc(temp, path, text: string) -> os.Error {
	err := os.rename(temp, path)
	for attempt := 0; err != nil && attempt < FILE_REPLACE_ATTEMPTS; attempt += 1 {
		time.sleep(10 * time.Millisecond)
		err = os.rename(temp, path)
	}
	if err == nil do return nil
	when ODIN_OS == .Windows {
		if os.write_entire_file(path, transmute([]byte)text) == nil {
			os.remove(temp)
			return nil
		}
	}
	return err
}

// How many more times `File_Replace` tries a rename that failed (10 ms apart)
FILE_REPLACE_ATTEMPTS :: 10

// Moves a written file's modification time past `before` when the clock didn't (a coarse file
// system clock gives two writes within a few milliseconds the same time)
@(private="file")
ensureNewerTime :: proc(path: string, before: time.Time) {
	now := ldtkModified(path)
	if time.diff(before, now) > 0 do return
	later := time.time_add(before, time.Millisecond)
	_ = os.change_times(path, later, later)
}

// The document's folder (the .ldtk file's)
LDtkDoc_Folder :: proc(doc: ^LDtkDoc) -> string {
	return filepath.dir(doc.files[0].path)
}
