package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

/*
The documentation the docs window shows (view_docs.odin), bundled and offline: the user manual
and the engine's API reference, as pages of Markdown (markdown.odin).

- **Addresses are the website's paths** (`/manual/scene-changes/#transitions`,
  `/api/camera/#camera2d_follow`), so "Open on crossfireengine.io" is the site's address plus
  the page's (`Docs_URL`), and links between pages work the same here and there.
- **The manual** is the editor's `docs/manual` (its .md files) (`Docs_ManualDir`: this checkout's, else
  beside the executable: `docs/manual`, a macOS bundle's `Resources/docs/manual`; releases ship
  it: tools/ci/package_editor.sh, tools/macos/bundle.sh). A page's address is its file name with
  dashes for underscores, as the website's scripts/sync-manual.mjs makes it (README.md is
  `/manual/`).
- **The API reference** is made here from the engine's doc comments as engine_docs.odin reads
  them (the engine the editor builds with: a checkout, or a release's `engine/` folder), laid
  out as the website's scripts/build-api.mjs lays it out: an index and a page per area of
  `ENGINE_API_AREAS` (the website's api-groups.json), each with its description, its files'
  overviews, then Types, Procedures, Constants and variables, a `### Name` per declaration
  (anchor: the name lower-cased) in the engine's source order. Inline code naming a
  declaration links to it.
- **Search** (`Docs_Search`) looks through every page's title and its sections (a heading and
  the text under it) for all the words of the query; titles first, then headings, then text.
- **Lookups** for the ways in: a node kind's guide (`DOCS_NODE_GUIDES`: the manual's node
  guide pages, a `## <Kind>` section each; a test checks every kind has one), an asset kind's
  page (`DOCS_ASSET_PAGES`), a bottom tab's (`DOCS_BOTTOM_TAB_PAGES`), an engine declaration's
  entry (`Docs_EngineAddress`) and a type in code (`Docs_TypeAddress`).

The library is read once, the first time the window opens (`Docs_Library`, the main thread: the
manual's files and the engine's table, which the code tabs usually read already), and kept for
the run on the heap.
*/

// The website the docs are published on
DOCS_SITE :: "https://crossfireengine.io"

// Where the manual is in a checkout of the editor
DOCS_MANUAL_SOURCE :: #directory + "/docs/manual"

// The editor's repository, for the manual's links to its files
DOCS_REPOSITORY :: "https://github.com/bcrowe306/crossfire-editor"

// One page of the docs
DocsPage :: struct {
	// Its address ("/manual/scene-changes/", "/api/camera/")
	address: string,
	// The manual's file name ("scene_changes.md"); "" for the API's pages
	file: string,
	title, description: string,
	// The manual's reading order (the API's pages after it, in the website's order)
	order: int,
	api: bool,
	doc: ^MdDoc,
	// Its sections for search: a heading (or the page's start) and the text under it
	sections: []DocsSection,
}

// A heading and the text under it until the next heading, lower-cased for search
DocsSection :: struct {
	anchor, heading: string,
	text: string,
	// The text as written (for the snippets search shows)
	original: string,
}

// Every page (manual first, in reading order, then the API reference)
DocsLibrary :: struct {
	pages: [dynamic]DocsPage,
	manualDir: string,
	// How long reading it took
	took: time.Duration,
}

@(private="file")
docsLibrary: struct {
	lock: sync.Mutex,
	lib: ^DocsLibrary,
}

/*
The docs, read the first time they're asked for (the manual from `Docs_ManualDir`, the API from
the engine's documentation, read now if no code tab read it yet).

Returns:
- The library (never nil: an empty one when nothing could be read)
*/
Docs_Library :: proc() -> ^DocsLibrary {
	sync.guard(&docsLibrary.lock)
	if docsLibrary.lib != nil do return docsLibrary.lib
	engineDir, _ := Toolchain_EngineDir()
	table := EngineDocs_Load(engineDir)
	docsLibrary.lib = DocsLibrary_Build(Docs_ManualDir(), table, runtime.heap_allocator())
	return docsLibrary.lib
}

/*
Where the manual's Markdown files are: this checkout's `docs/manual`, else beside the executable
(`docs/manual`; a macOS bundle's `Contents/Resources/docs/manual`).

Returns:
- The folder ("" when there's none)
*/
Docs_ManualDir :: proc() -> string {
	if os.exists(joinPath(DOCS_MANUAL_SOURCE, "README.md", allocator = context.temp_allocator)) do return DOCS_MANUAL_SOURCE
	if exeDir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for dir in ([]string{joinPath(exeDir, "docs", "manual", allocator = context.temp_allocator), joinPath(exeDir, "..", "Resources", "docs", "manual", allocator = context.temp_allocator)}) {
			if os.exists(joinPath(dir, "README.md", allocator = context.temp_allocator)) do return dir
		}
	}
	return ""
}

/*
Reads the docs (pure: tests call it).

Inputs:
- manualDir: The manual's folder ("" none)
- table: The engine's documentation (nil: no API reference)
- allocator: For the library and everything in it

Returns:
- The library (free it with DocsLibrary_Destroy)
*/
DocsLibrary_Build :: proc(manualDir: string, table: ^EngineDocs, allocator := context.allocator) -> ^DocsLibrary {
	start := time.tick_now()
	context.allocator = allocator
	lib := new(DocsLibrary)
	lib.pages = make([dynamic]DocsPage)
	lib.manualDir = strings.clone(manualDir)
	if manualDir != "" {
		if entries, err := os.read_all_directory_by_path(manualDir, context.temp_allocator); err == nil {
			for entry in entries {
				if !strings.has_suffix(entry.name, ".md") do continue
				data, readErr := os.read_entire_file(entry.fullpath, context.temp_allocator)
				if readErr != nil do continue
				doc := Markdown_Parse(string(data))
				if doc == nil do continue
				slug := Docs_ManualSlug(entry.name)
				append(&lib.pages, DocsPage{
					address = slug == "" ? strings.clone("/manual/") : fmt.aprintf("/manual/%s/", slug),
					file = strings.clone(entry.name),
					title = strings.clone(doc.title != "" ? doc.title : slug),
					description = strings.clone(doc.description),
					order = doc.order,
					doc = doc,
				})
			}
		}
		slice.sort_by(lib.pages[:], proc(a, b: DocsPage) -> bool { return a.order < b.order || a.order == b.order && a.file < b.file })
	}
	if table != nil do docsApiPages(lib, table)
	for &p in lib.pages do p.sections = docsSections(p.doc)
	lib.took = time.tick_since(start)
	return lib
}

// Frees a library
DocsLibrary_Destroy :: proc(lib: ^DocsLibrary, allocator := context.allocator) {
	if lib == nil do return
	context.allocator = allocator
	for p in lib.pages {
		delete(p.address); delete(p.file); delete(p.title); delete(p.description)
		for s in p.sections { delete(s.anchor); delete(s.heading); delete(s.text); delete(s.original) }
		delete(p.sections)
		MdDoc_Destroy(p.doc)
	}
	delete(lib.pages)
	delete(lib.manualDir)
	free(lib)
}

// A manual file's slug on the website ("scene_changes.md" -> "scene-changes"; README.md -> "")
Docs_ManualSlug :: proc(file: string) -> string {
	base := strings.trim_suffix(filepath.base(file), ".md")
	if base == "README" do return ""
	slug, _ := strings.replace_all(base, "_", "-", context.temp_allocator)
	return slug
}

// The search sections of a page (its heading-led runs of text)
@(private="file")
docsSections :: proc(doc: ^MdDoc) -> []DocsSection {
	out := make([dynamic]DocsSection)
	b := strings.builder_make(context.temp_allocator)
	anchor, heading := "", ""
	flush :: proc(out: ^[dynamic]DocsSection, b: ^strings.Builder, anchor, heading: string) {
		text := strings.to_string(b^)
		if heading == "" && strings.trim_space(text) == "" do return
		append(out, DocsSection{
			anchor = strings.clone(anchor), heading = strings.clone(heading),
			text = strings.to_lower(text), original = strings.clone(text),
		})
		strings.builder_reset(b)
	}
	for blk in doc.blocks {
		if blk.kind == .Heading {
			flush(&out, &b, anchor, heading)
			anchor, heading = blk.anchor, blk.text
			continue
		}
		switch blk.kind {
		case .Paragraph, .Quote:
			for s in blk.spans do strings.write_string(&b, s.text)
		case .List:
			for item in blk.items {
				for s in item.spans do strings.write_string(&b, s.text)
				strings.write_string(&b, "; ")
			}
		case .Table:
			for row in blk.rows {
				for cell, c in row {
					if c > 0 do strings.write_string(&b, ": ")
					for s in cell do strings.write_string(&b, s.text)
				}
				strings.write_string(&b, "; ")
			}
		case .Code:
			strings.write_string(&b, blk.code)
		case .Heading, .Rule:
		}
		strings.write_byte(&b, ' ')
	}
	flush(&out, &b, anchor, heading)
	return out[:]
}

// --- addresses ---------------------------------------------------------------------------

/*
A manual page's address ("" the contents; "scene_changes", or "scene_changes#transitions").

Returns:
- The address (temp allocated)
*/
Docs_ManualAddress :: proc(page: string) -> string {
	name, anchor := page, ""
	if hash := strings.index_byte(page, '#'); hash >= 0 do name, anchor = page[:hash], page[hash:]
	name = strings.trim_suffix(name, ".md")
	if name == "" || name == "README" do return fmt.tprintf("/manual/%s", anchor)
	slug, _ := strings.replace_all(name, "_", "-", context.temp_allocator)
	return fmt.tprintf("/manual/%s/%s", slug, anchor)
}

// An address's page and anchor ("/api/camera/#zoom" -> "/api/camera/", "zoom")
Docs_SplitAddress :: proc(address: string) -> (page, anchor: string) {
	if hash := strings.index_byte(address, '#'); hash >= 0 do return address[:hash], address[hash + 1:]
	return address, ""
}

// An address on the website (temp allocated)
Docs_URL :: proc(address: string) -> string {
	return fmt.tprintf("%s%s", DOCS_SITE, address)
}

/*
The address of a link to the website (`https://crossfireengine.io/api/camera/#zoom`), when it's a
page the docs have (the manual's or the API's).

Returns:
- The address (temp allocated) and whether it's one
*/
Docs_FromURL :: proc(url: string) -> (string, bool) {
	rest: string
	switch {
	case strings.has_prefix(url, DOCS_SITE):          rest = url[len(DOCS_SITE):]
	case strings.has_prefix(url, "https://www.crossfireengine.io"): rest = url[len("https://www.crossfireengine.io"):]
	case strings.has_prefix(url, "http://crossfireengine.io"): rest = url[len("http://crossfireengine.io"):]
	case: return "", false
	}
	if !strings.has_prefix(rest, "/manual") && !strings.has_prefix(rest, "/api") do return "", false
	return docsNormalize(rest), true
}

// An address with its page's trailing slash ("/api/camera#x" -> "/api/camera/#x")
@(private="file")
docsNormalize :: proc(address: string) -> string {
	page, anchor := Docs_SplitAddress(address)
	if !strings.has_suffix(page, "/") do page = fmt.tprintf("%s/", page)
	if anchor == "" do return strings.clone(page, context.temp_allocator)
	return fmt.tprintf("%s#%s", page, anchor)
}

/*
Where a link on a page goes: another page of the docs (an address), or somewhere else (a web
address for the browser).

- `#anchor`: the same page
- the website's pages, absolute (`/api/...`) or as `https://crossfireengine.io/...`
- a manual page, relative (`scene_changes.md#transitions`)
- another file of the editor's repository (relative to docs/manual): its page on GitHub
- anything else with a scheme (https, mailto): as it is

Inputs:
- from: The page's address
- target: The link as written

Returns:
- The docs address ("" when it isn't one) or the external address (temp allocated)
*/
Docs_ResolveLink :: proc(from, target: string) -> (address, external: string) {
	t := strings.trim_space(target)
	if t == "" do return "", ""
	if strings.has_prefix(t, "#") {
		page, _ := Docs_SplitAddress(from)
		return fmt.tprintf("%s%s", page, t), ""
	}
	if a, ok := Docs_FromURL(t); ok do return a, ""
	if strings.has_prefix(t, "/manual") || strings.has_prefix(t, "/api") do return docsNormalize(t), ""
	if strings.has_prefix(t, "/") do return "", Docs_URL(t)
	if strings.index(t, "://") > 0 || strings.has_prefix(t, "mailto:") do return "", t
	// Relative: from the manual's folder (the API's pages have no relative links of their own)
	pathPart, anchor := t, ""
	if hash := strings.index_byte(t, '#'); hash >= 0 do pathPart, anchor = t[:hash], t[hash:]
	pathPart = strings.trim_prefix(pathPart, "./")
	resolved, _ := filepath.join({"docs/manual", pathPart}, context.temp_allocator)
	resolved, _ = strings.replace_all(resolved, "\\", "/", context.temp_allocator)
	if strings.has_suffix(resolved, ".md") && strings.has_prefix(resolved, "docs/manual/") && !strings.contains(resolved[len("docs/manual/"):], "/") {
		return Docs_ManualAddress(fmt.tprintf("%s%s", filepath.base(resolved), anchor)), ""
	}
	return "", fmt.tprintf("%s/blob/main/%s%s", DOCS_REPOSITORY, resolved, anchor)
}

// The page at an address (its anchor ignored; nil none)
DocsLibrary_Find :: proc(lib: ^DocsLibrary, address: string) -> ^DocsPage {
	if lib == nil do return nil
	page, _ := Docs_SplitAddress(address)
	if !strings.has_suffix(page, "/") do page = fmt.tprintf("%s/", page)
	for &p in lib.pages do if p.address == page do return &p
	return nil
}

// Whether a page has a heading with the anchor
DocsPage_HasAnchor :: proc(p: ^DocsPage, anchor: string) -> bool {
	if p == nil || p.doc == nil do return false
	for b in p.doc.blocks do if b.kind == .Heading && b.anchor == anchor do return true
	return false
}

// --- lookups -------------------------------------------------------------------------------

/*
Each node kind's guide: the manual page with its `## <Kind>` section (its anchor the kind's name
lower-cased). `docs_every_node_kind_has_a_guide` checks every kind has one.
*/
DOCS_NODE_GUIDES := [NodeKind]string{
	.Node2D = "nodes_scene", .Camera = "nodes_scene", .Component = "nodes_scene", .LDtkLevel = "nodes_scene",
	.CameraZone = "nodes_scene", .NavRegion = "nodes_scene", .NavAgent = "nodes_scene",
	.Sprite = "nodes_graphics", .AnimatedSprite = "nodes_graphics", .TileMap = "nodes_graphics",
	.ParallaxLayer = "nodes_graphics", .CameraView = "nodes_graphics", .Light2D = "nodes_graphics",
	.LightOccluder = "nodes_graphics", .ScreenEffect = "nodes_graphics", .Line2D = "nodes_graphics",
	.Trail2D = "nodes_graphics", .ParticleEmitter = "nodes_graphics",
	.Animator = "nodes_animation", .StateMachine = "nodes_animation", .Skeleton2D = "nodes_animation",
	.Bone2D = "nodes_animation", .SkinnedMesh = "nodes_animation", .IKChain = "nodes_animation",
	.Label = "nodes_ui", .Menu = "nodes_ui", .Panel = "nodes_ui", .Button = "nodes_ui",
	.ProgressBar = "nodes_ui", .TextField = "nodes_ui", .ScrollBox = "nodes_ui", .RichText = "nodes_ui",
	.Slider = "nodes_ui", .CheckBox = "nodes_ui", .DialogueBox = "nodes_ui", .VirtualJoystick = "nodes_ui",
	.TouchButton = "nodes_ui",
	.StaticBody = "nodes_physics", .DynamicBody = "nodes_physics", .CharacterMover = "nodes_physics",
	.Area = "nodes_physics", .CollisionShape = "nodes_physics", .RayCast = "nodes_physics", .Joint = "nodes_physics",
	.AudioPlayer = "nodes_audio", .AudioPlayer2D = "nodes_audio", .MusicPlayer = "nodes_audio",
}

// A node kind's guide (temp allocated): `/manual/nodes-graphics/#sprite`
Docs_NodeKindAddress :: proc(kind: NodeKind) -> string {
	return Docs_ManualAddress(fmt.tprintf("%s#%s", DOCS_NODE_GUIDES[kind], strings.to_lower(fmt.tprintf("%v", kind), context.temp_allocator)))
}

// Each asset kind's page of the manual (and section); checked by `docs_every_kind_has_a_page`
DOCS_ASSET_PAGES := [AssetKind]string{
	.Image           = "sprites_and_images#bringing-in-pictures",
	.Audio           = "sound#sounds-and-music-in-the-project",
	.Music           = "sound#sounds-and-music-in-the-project",
	.Font            = "asset_import#fonts-that-stay-sharp-at-any-size-msdf",
	.Data            = "globals_data_saves#data-resources",
	.Component       = "components",
	.LDtk            = "levels#importing-an-ldtk-project",
	.Translation     = "localization#translation-tables",
	.Animation       = "sprites_and_images#animation-assets-animations-sprites-share",
	.Theme           = "ui#themes-how-controls-look",
	.PhysicsMaterial = "collision_and_materials#physics-materials",
	.Shader          = "shaders#writing-your-own-shader",
	.Atlas           = "asset_import#texture-atlases",
	.Dialogue        = "dialogue",
}

// Each bottom tab's page of the manual (F1 over the bottom panel)
DOCS_BOTTOM_TAB_PAGES := [BottomTab]string{
	.Console   = "scripts#logging",
	.Output    = "scripts#building-ctrlb-and-the-output-tab",
	.Animation = "sprites_and_images#the-animation-panel",
	.Mixer     = "sound#the-mixer-buses",
	.Git       = "version_control",
	.Tiles     = "tilemaps",
	.Timeline  = "animation#the-timeline-tab",
	.Live      = "live",
	.States    = "state_machines",
	.Dialogue  = "dialogue",
	.Plugins   = "plugins",
	.LDtk      = "level_mode#the-ldtk-tab",
}

// The other places' pages (scenes, scripts, the editor's panels)
DOCS_SCENE_PAGE      :: "scenes_and_nodes#scenes"
DOCS_SCRIPT_PAGE     :: "scripts"
DOCS_CODE_PAGE       :: "code_editor"
DOCS_VIEWPORT_PAGE   :: "scenes_and_nodes#the-viewport"
DOCS_SCENE_TREE_PAGE :: "scenes_and_nodes#the-scene-tree"
DOCS_INSPECTOR_PAGE  :: "scenes_and_nodes#every-nodes-settings"
DOCS_BROWSER_PAGE    :: "projects"

// An asset kind's page (temp allocated)
Docs_AssetKindAddress :: proc(kind: AssetKind) -> string {
	return Docs_ManualAddress(DOCS_ASSET_PAGES[kind])
}

// An engine declaration's entry in the API reference (temp allocated): `/api/camera/#camera2d`;
// the reference's index when its file is in no area
Docs_EngineAddress :: proc(d: EngineDoc) -> string {
	area := EngineAPI_Area(d.file)
	if area == "" do return "/api/"
	return fmt.tprintf("/api/%s/#%s", area, strings.to_lower(d.name, context.temp_allocator))
}

// The node kind an engine type is built for ("Camera2D" -> .Camera; the first kind of a shared
// type: Node is Node2D's, AudioPlayer AudioPlayer's), and whether there's one
Docs_NodeKindOfType :: proc(typeName: string) -> (NodeKind, bool) {
	for kind in NodeKind do if NodeField_TypeName(kind) == typeName do return kind, true
	return {}, false
}

/*
Where a type written in code goes (`^e.Door`, `e.Sprite`, `[]^e.Area`): an engine node type's
guide, `e.Script` the scripts page, any other engine declaration its API entry. A type of the
project's own (`^Door`, with `Door :: struct { using sprite: e.Sprite }`) goes through what it
embeds (`projectTypes`): the Sprite's guide.

Inputs:
- typeText: The type as written
- alias: The file's import name of the engine
- table: The engine's documentation (nil: only node types are known)
- projectTypes: The project's structs by name, each to the type its first field embeds with
  `using` (`ScriptIndex_Embeds`; nil: none)

Returns:
- The address ("" when it isn't the engine's; temp allocated)
*/
Docs_TypeAddress :: proc(typeText, alias: string, table: ^EngineDocs, projectTypes: map[string]string = nil, depth := 0) -> string {
	t := strings.trim_space(typeText)
	// Through pointers, slices, arrays and maps' values
	for {
		switch {
		case strings.has_prefix(t, "^"):  t = t[1:]
		case strings.has_prefix(t, "[^]"): t = t[3:]
		case strings.has_prefix(t, "["):
			if close := strings.index_byte(t, ']'); close > 0 do t = t[close + 1:]
			else do return ""
		case strings.has_prefix(t, "map["):
			if close := strings.index_byte(t, ']'); close > 0 do t = t[close + 1:]
			else do return ""
		case:
			t = strings.trim_space(t)
			if alias == "" || !strings.has_prefix(t, alias) || len(t) <= len(alias) + 1 || t[len(alias)] != '.' {
				// The project's own type: what it embeds (a chain of them, not forever)
				name := t
				if paren := strings.index_any(name, "( {"); paren >= 0 do name = name[:paren]
				if embeds, ok := projectTypes[name]; ok && embeds != "" && depth < 8 do return Docs_TypeAddress(embeds, alias, table, projectTypes, depth + 1)
				return ""
			}
			name := t[len(alias) + 1:]
			if paren := strings.index_any(name, "( {"); paren >= 0 do name = name[:paren]
			return Docs_EngineNameAddress(name, table)
		}
	}
}

/*
Where an engine name goes for "Open Docs": a node type's guide, `Script` the scripts page, any
other declaration its API entry ("" when the engine has no such name; temp allocated).
*/
Docs_EngineNameAddress :: proc(name: string, table: ^EngineDocs) -> string {
	if kind, ok := Docs_NodeKindOfType(name); ok && name != "Node" do return Docs_NodeKindAddress(kind)
	if name == "Script" do return Docs_ManualAddress(DOCS_SCRIPT_PAGE)
	if table != nil {
		if d, ok := table.decls[name]; ok do return Docs_EngineAddress(d)
	}
	return ""
}

// --- search --------------------------------------------------------------------------------

// One search result: a page, maybe a section of it
DocsHit :: struct {
	page: int,
	// The section's anchor ("" the page itself) and heading
	anchor, heading: string,
	// Text around the first match (temp allocated)
	snippet: string,
	score: int,
}

DOCS_SEARCH_MAX :: 60

/*
Searches the docs: every word of the query (case ignored) in a page's title, a section's heading
or its text. Pages whose title matches come first, then sections whose heading does (an API
entry named exactly the query before them all), then text.

Returns:
- At most DOCS_SEARCH_MAX hits, best first (temp allocated)
*/
Docs_Search :: proc(lib: ^DocsLibrary, query: string) -> []DocsHit {
	words := strings.fields(strings.to_lower(query, context.temp_allocator), context.temp_allocator)
	hits := make([dynamic]DocsHit, context.temp_allocator)
	if lib == nil || len(words) == 0 do return hits[:]
	all :: proc(text: string, words: []string) -> bool {
		for w in words do if !strings.contains(text, w) do return false
		return true
	}
	q := strings.join(words, " ", context.temp_allocator)
	for &p, pi in lib.pages {
		title := strings.to_lower(p.title, context.temp_allocator)
		if all(title, words) do append(&hits, DocsHit{page = pi, snippet = p.description, score = title == q ? 120 : 100})
		for s in p.sections {
			heading := strings.to_lower(s.heading, context.temp_allocator)
			score := 0
			if s.heading != "" && all(heading, words) {
				score = heading == q ? 110 : 50
				if p.api && score == 50 do score = 40
			} else if all(s.text, words) || s.heading != "" && all(fmt.tprintf("%s %s", heading, s.text), words) {
				score = p.api ? 5 : 10
			}
			if score == 0 do continue
			// The manual's first heading repeats the page's title: the page itself
			// (found already when the title matched)
			if s.heading == p.title && all(title, words) do continue
			hitAnchor, hitHeading := s.anchor, s.heading
			if hitHeading == p.title do hitAnchor, hitHeading = "", ""
			append(&hits, DocsHit{page = pi, anchor = hitAnchor, heading = hitHeading, snippet = docsSnippet(s, words[0]), score = score})
		}
	}
	slice.stable_sort_by(hits[:], proc(a, b: DocsHit) -> bool { return a.score > b.score })
	return hits[:min(len(hits), DOCS_SEARCH_MAX)]
}

// About a line of text around a word's first place in a section
@(private="file")
docsSnippet :: proc(s: DocsSection, word: string) -> string {
	at := strings.index(s.text, word)
	if at < 0 do at = 0
	start := md_runeStart(s.original, max(at - 40, 0))
	end := md_runeStart(s.original, min(at + 80, len(s.original)))
	if end < len(s.original) && end < start + 1 do end = len(s.original)
	// Its words with single spaces (code's indentation and line breaks)
	text := strings.join(strings.fields(s.original[start:end], context.temp_allocator), " ", context.temp_allocator)
	return fmt.tprintf("%s%s%s", start > 0 ? "..." : "", text, end < len(s.original) ? "..." : "")
}

// --- the API reference -----------------------------------------------------------------------

@(private="file")
DOCS_TYPE_KINDS :: []string{"struct", "enum", "union", "bit_set", "bit_field", "distinct", "type"}

@(private="file")
docsKindLabel :: proc(kind: string) -> string {
	switch kind {
	case "proc":       return "procedure"
	case "proc_group": return "procedure group"
	case "distinct":   return "distinct type"
	}
	return kind
}

// The API reference's pages: its index, then a page per area (build-api.mjs's layout)
@(private="file")
docsApiPages :: proc(lib: ^DocsLibrary, table: ^EngineDocs) {
	// Each area's declarations in source order (its files in the area's order, then by line)
	perArea := make([][dynamic]EngineDoc, len(ENGINE_API_AREAS), context.temp_allocator)
	for &list in perArea do list = make([dynamic]EngineDoc, context.temp_allocator)
	areaOf := make(map[string]int, allocator = context.temp_allocator)
	for area, i in ENGINE_API_AREAS do for f in area.files do areaOf[f] = i
	for _, d in table.decls {
		if i, ok := areaOf[d.file]; ok do append(&perArea[i], d)
	}
	for &list, i in perArea {
		files := ENGINE_API_AREAS[i].files
		fileIndex :: proc(files: []string, f: string) -> int {
			for x, i in files do if x == f do return i
			return len(files)
		}
		context.user_ptr = &files
		slice.sort_by(list[:], proc(a, b: EngineDoc) -> bool {
			files := (^[]string)(context.user_ptr)^
			fa, fb := fileIndex(files, a.file), fileIndex(files, b.file)
			return fa < fb || fa == fb && a.line < b.line
		})
	}
	// Where each name is documented, for links
	pageOf := make(map[string]string, allocator = context.temp_allocator)
	for list, i in perArea do for d in list do pageOf[d.name] = ENGINE_API_AREAS[i].slug

	total := 0
	for list in perArea do total += len(list)
	order := 1000
	{
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "The Crossfire Engine's public API, generated from the doc comments in its source (package `crossfire`, imported by games as `import e \"engine:.\"`). %d declarations in %d areas.\n\n", total, len(ENGINE_API_AREAS))
		if table.packageDoc != "" {
			strings.write_string(&b, "## The package\n\n")
			strings.write_string(&b, docsDocMarkdown(table.packageDoc, "", pageOf))
			strings.write_string(&b, "\n\n")
		}
		strings.write_string(&b, "## Areas\n\n")
		for area, i in ENGINE_API_AREAS do fmt.sbprintf(&b, "- [%s](/api/%s/): %s (%d)\n", area.title, area.slug, docsInline(area.description, "", pageOf), len(perArea[i]))
		docsAddApiPage(lib, "/api/", "Engine API reference", "Every public type, procedure and constant of the Crossfire Engine, from its doc comments.", order, strings.to_string(b))
	}
	for area, i in ENGINE_API_AREAS {
		order += 1
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%s\n\n", docsInline(area.description, area.slug, pageOf))
		strings.write_string(&b, "Files: ")
		for f, fi in area.files do fmt.sbprintf(&b, "%s`%s`", fi > 0 ? ", " : "", f)
		strings.write_string(&b, ".\n\n")
		withOverview := 0
		for f in area.files do if f in table.overviews do withOverview += 1
		if withOverview > 0 {
			strings.write_string(&b, "## File overviews\n\n")
			for f in area.files {
				overview, ok := table.overviews[f]
				if !ok do continue
				if withOverview > 1 do fmt.sbprintf(&b, "### %s\n\n", f)
				else do fmt.sbprintf(&b, "From `%s`:\n\n", f)
				fmt.sbprintf(&b, "%s\n\n", docsDocMarkdown(overview, area.slug, pageOf))
			}
		}
		Section :: enum { Types, Procedures, Constants }
		titles := [Section]string{.Types = "Types", .Procedures = "Procedures", .Constants = "Constants and variables"}
		for section in Section {
			first := true
			for d in perArea[i] {
				isType := slice.contains(DOCS_TYPE_KINDS, d.kind)
				isProc := d.kind == "proc" || d.kind == "proc_group"
				in_ := section == .Types ? isType : section == .Procedures ? isProc : !isType && !isProc
				if !in_ do continue
				if first do fmt.sbprintf(&b, "## %s\n\n", titles[section])
				first = false
				fmt.sbprintf(&b, "### %s\n\n", d.name)
				fence := strings.contains(d.decl, "```") ? "````" : "```"
				fmt.sbprintf(&b, "%sodin\n%s\n%s\n\n", fence, d.decl, fence)
				if d.doc != "" do fmt.sbprintf(&b, "%s\n\n", docsDocMarkdown(d.doc, area.slug, pageOf))
				fmt.sbprintf(&b, "*%s, %s:%d*\n\n", docsKindLabel(d.kind), d.file, d.line)
			}
		}
		if len(perArea[i]) == 0 do strings.write_string(&b, "These files declare nothing public.\n")
		docsAddApiPage(lib, fmt.tprintf("/api/%s/", area.slug), area.title, area.description, order, strings.to_string(b))
	}
}

@(private="file")
docsAddApiPage :: proc(lib: ^DocsLibrary, address, title, description: string, order: int, markdown: string) {
	doc := Markdown_Parse(markdown)
	if doc == nil do return
	append(&lib.pages, DocsPage{
		address = strings.clone(address), title = strings.clone(title), description = strings.clone(description),
		order = order, api = true, doc = doc,
	})
}

/*
A doc comment (Odin core style) as Markdown, as the website's build-api.mjs makes it: paragraphs
kept, `Label:` lines bold, `Inputs:` / `Returns:` lists with bold names, tab-indented blocks as
code (Odin under `Example:` or when they look like it), inline code naming a declaration linked
to it. Temp allocated.
*/
@(private="file")
docsDocMarkdown :: proc(doc, slug: string, pageOf: map[string]string) -> string {
	lines := strings.split_lines(doc, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	label := ""
	inList := false
	blank :: proc(out: ^[dynamic]string) { if len(out) > 0 && out[len(out) - 1] != "" do append(out, "") }
	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		if strings.has_prefix(line, "\t") {
			block := make([dynamic]string, context.temp_allocator)
			j := i
			for ; j < len(lines); j += 1 {
				if strings.has_prefix(lines[j], "\t") {
					append(&block, lines[j][1:])
				} else if strings.trim_space(lines[j]) == "" {
					// A blank line inside the block when an indented line follows
					k := j + 1
					for k < len(lines) && strings.trim_space(lines[k]) == "" do k += 1
					if k < len(lines) && strings.has_prefix(lines[k], "\t") do append(&block, "")
					else do break
				} else {
					break
				}
			}
			i = j - 1
			lang := "text"
			first := ""
			for l in block do if strings.trim_space(l) != "" { first = strings.trim_space(l); break }
			looksOdin := false
			for l in block do if strings.contains(l, "::") || strings.contains(l, ":=") || strings.contains(l, "proc") || strings.contains(l, "e.") do looksOdin = true
			switch {
			case label == "Example": lang = "odin"
			case strings.has_prefix(first, "<"): lang = "xml"
			case looksOdin: lang = "odin"
			}
			blank(&out)
			append(&out, fmt.tprintf("```%s", lang))
			append(&out, ..block[:])
			append(&out, "```", "")
			inList = false
			continue
		}
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			append(&out, "")
			inList = false
			if label != "" && label != "Inputs" && label != "Returns" do label = ""
			continue
		}
		if strings.has_suffix(trimmed, ":") && len(trimmed) > 1 && trimmed[0] >= 'A' && trimmed[0] <= 'Z' && docsIsLabel(trimmed[:len(trimmed) - 1]) {
			label = trimmed[:len(trimmed) - 1]
			blank(&out)
			append(&out, fmt.tprintf("**%s**", label), "")
			inList = false
			continue
		}
		if strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") {
			item := trimmed
			if (label == "Inputs" || label == "Returns") && strings.has_prefix(item, "- ") {
				if colon := strings.index(item, ": "); colon > 2 {
					names := item[2:colon]
					simple := true
					for c in names do if !(c == '_' || c == '.' || c == ',' || c == ' ' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') do simple = false
					if simple {
						parts := strings.split(names, ", ", context.temp_allocator)
						for &p in parts do p = fmt.tprintf("**%s**", p)
						item = fmt.tprintf("- %s: %s", strings.join(parts, ", ", context.temp_allocator), item[colon + 2:])
					}
				}
			}
			indent := len(line) - len(strings.trim_left_space(line)) > 0 && inList ? "  " : ""
			append(&out, fmt.tprintf("%s%s", indent, docsInline(item, slug, pageOf)))
			inList = true
			continue
		}
		text := docsInline(trimmed, slug, pageOf)
		if strings.has_prefix(text, "#") do text = fmt.tprintf("\\%s", text)
		append(&out, fmt.tprintf("%s%s", inList ? "  " : "", text))
		if label == "Example" do label = ""
	}
	return strings.trim_space(strings.join(out[:], "\n", context.temp_allocator))
}

// A `Label:` line's label (words starting with a capital: "Inputs", "See also")
@(private="file")
docsIsLabel :: proc(s: string) -> bool {
	for c in s do if !(c == ' ' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') do return false
	return true
}

// Inline code naming a declaration (`Camera2D_Follow`, `e.Camera2D_Follow()`) as a link to it
@(private="file")
docsInline :: proc(text, slug: string, pageOf: map[string]string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		if text[i] != '`' {
			strings.write_byte(&b, text[i])
			i += 1
			continue
		}
		end := strings.index_byte(text[i + 1:], '`')
		if end < 0 {
			strings.write_string(&b, text[i:])
			break
		}
		span := text[i:i + end + 2]
		name := strings.trim_suffix(strings.trim_prefix(span[1:len(span) - 1], "e."), "()")
		if page, ok := pageOf[name]; ok && docsIsIdent(name) {
			target := page == slug ? fmt.tprintf("#%s", strings.to_lower(name, context.temp_allocator)) : fmt.tprintf("/api/%s/#%s", page, strings.to_lower(name, context.temp_allocator))
			fmt.sbprintf(&b, "[%s](%s)", span, target)
		} else {
			strings.write_string(&b, span)
		}
		i += end + 2
	}
	return strings.to_string(b)
}

@(private="file")
docsIsIdent :: proc(s: string) -> bool {
	if s == "" do return false
	for c, i in s do if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && c >= '0' && c <= '9') do return false
	return true
}
