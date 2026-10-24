package crossfire_editor

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "core:time"

// The markdown parser: frontmatter, every block kind, inline styles, anchors
@(test)
docs_markdown_parse :: proc(t: ^testing.T) {
	source := `---
title: "Scenes: and nodes"
description: A page
order: 7
---

# Scenes: and nodes

A **bold** and *italic* word, ` + "`e.Node`" + `, a [link](other.md#x) and snake_case_name.
Joined line with \*stars\* &lt;tag&gt;.

## Layers: who collides with whom

- one
- two **b**
  continued
  - nested
1. first
2. second

| Setting | What it does |
|---|:---:|
| **Area width** | a ` + "`|`" + ` bar |
| one |

` + "```odin title=\"x.odin\"" + `
Hero :: struct {}
` + "```" + `

> a quote

---

![logo](assets/logo.png)

## Layers: who collides with whom
`
	doc := Markdown_Parse(source)
	defer MdDoc_Destroy(doc)
	testing.expect_value(t, doc.title, "Scenes: and nodes")
	testing.expect_value(t, doc.description, "A page")
	testing.expect_value(t, doc.order, 7)
	kinds := make([dynamic]MdBlockKind, context.temp_allocator)
	for b in doc.blocks do append(&kinds, b.kind)
	expected := []MdBlockKind{.Heading, .Paragraph, .Heading, .List, .List, .Table, .Code, .Quote, .Rule, .Paragraph, .Heading}
	testing.expectf(t, len(kinds) == len(expected), "the blocks: %v", kinds)
	for k, i in expected do if i < len(kinds) do testing.expectf(t, kinds[i] == k, "block %d is %v, not %v", i, kinds[i], k)
	if len(doc.blocks) < len(expected) do return

	// Inline styles
	p := doc.blocks[1].spans
	find :: proc(spans: []MdSpan, text: string) -> (MdSpan, bool) {
		for s in spans do if s.text == text do return s, true
		return {}, false
	}
	bold, b1 := find(p, "bold")
	testing.expect(t, b1 && bold.bold && !bold.italic, "bold")
	italic, i1 := find(p, "italic")
	testing.expect(t, i1 && italic.italic, "italic")
	code, c1 := find(p, "e.Node")
	testing.expect(t, c1 && code.code, "inline code")
	link, l1 := find(p, "link")
	testing.expect(t, l1 && link.link == "other.md#x", "a link")
	plain := MdSpans_Plain(p, context.temp_allocator)
	testing.expectf(t, strings.contains(plain, "snake_case_name") && strings.contains(plain, "*stars* <tag>"), "underscores in words, escapes, entities: %s", plain)
	testing.expect(t, strings.contains(plain, "name. Joined"), "a paragraph's lines joined")

	// Headings and anchors (Starlight's), repeated ones numbered
	testing.expect_value(t, doc.blocks[0].anchor, "scenes-and-nodes")
	testing.expect_value(t, doc.blocks[2].anchor, "layers-who-collides-with-whom")
	testing.expect_value(t, doc.blocks[10].anchor, "layers-who-collides-with-whom-1")
	testing.expect_value(t, Markdown_Slug("Frame times: is the game fast enough?", context.temp_allocator), "frame-times-is-the-game-fast-enough")
	testing.expect_value(t, Markdown_Slug("Building: Ctrl+B and the Output tab", context.temp_allocator), "building-ctrlb-and-the-output-tab")
	testing.expect_value(t, Markdown_Slug("Camera2D_Follow", context.temp_allocator), "camera2d_follow")
	testing.expect_value(t, Markdown_Slug("Every node's settings", context.temp_allocator), "every-nodes-settings")

	// Lists: items, continuation, depth, numbers
	list := doc.blocks[3]
	testing.expect_value(t, len(list.items), 3)
	if len(list.items) == 3 {
		testing.expect_value(t, MdSpans_Plain(list.items[1].spans, context.temp_allocator), "two b continued")
		testing.expect_value(t, list.items[2].depth, 1)
	}
	ordered := doc.blocks[4]
	testing.expect(t, ordered.ordered && len(ordered.items) == 2 && ordered.items[1].number == 2, "a numbered list")

	// Tables: cells, a bar in code, a short row filled out, alignment
	table := doc.blocks[5]
	testing.expect_value(t, len(table.rows), 3)
	if len(table.rows) == 3 {
		testing.expect_value(t, len(table.rows[2]), 2)
		testing.expect_value(t, MdSpans_Plain(table.rows[1][1], context.temp_allocator), "a | bar")
		testing.expect_value(t, table.align[1], MdAlign.Center)
	}
	testing.expect_value(t, doc.blocks[6].lang, "odin")
	testing.expect_value(t, doc.blocks[6].code, "Hero :: struct {}")
	img := doc.blocks[9].spans
	testing.expect(t, len(img) == 1 && img[0].image && img[0].link == "assets/logo.png" && img[0].text == "logo", "an image")
}

// A parse keeps nothing of its source: blocks hold their own copies (the file's buffer is freed)
@(test)
docs_markdown_owns_its_text :: proc(t: ^testing.T) {
	source := strings.clone("---\ntitle: Kept\n---\n\n```odin\nHero :: struct {}\n```\n")
	doc := Markdown_Parse(source)
	defer MdDoc_Destroy(doc)
	for &c in transmute([]u8)source do c = 'x'
	delete(source)
	testing.expect_value(t, doc.title, "Kept")
	if testing.expect_value(t, len(doc.blocks), 1) do testing.expect_value(t, doc.blocks[0].lang, "odin")
}

// Links: within the page, other manual pages, the website, the repository's files, the web
@(test)
docs_links_resolve :: proc(t: ^testing.T) {
	Case :: struct { from, target, address, external: string }
	for c in ([]Case{
		{"/manual/physics/", "#joints", "/manual/physics/#joints", ""},
		{"/manual/physics/", "scene_changes.md#transitions", "/manual/scene-changes/#transitions", ""},
		{"/manual/", "README.md", "/manual/", ""},
		{"/manual/physics/", "./input.md", "/manual/input/", ""},
		{"/manual/x/", "https://crossfireengine.io/api/camera/#camera2d", "/api/camera/#camera2d", ""},
		{"/manual/x/", "https://crossfireengine.io/api", "/api/", ""},
		{"/api/camera/", "/api/core/#node", "/api/core/#node", ""},
		{"/manual/x/", "https://crossfireengine.io/download/", "", "https://crossfireengine.io/download/"},
		{"/manual/x/", "https://odin-lang.org", "", "https://odin-lang.org"},
		{"/manual/x/", "../../tools/demo/make_demo.py", "", "https://github.com/bcrowe306/crossfire-editor/blob/main/tools/demo/make_demo.py"},
	}) {
		address, external := Docs_ResolveLink(c.from, c.target)
		testing.expectf(t, address == c.address && external == c.external, "%s from %s: %q %q", c.target, c.from, address, external)
	}
	testing.expect_value(t, Docs_ManualAddress(""), "/manual/")
	testing.expect_value(t, Docs_ManualAddress("audio_effects_and_music"), "/manual/audio-effects-and-music/")
	testing.expect_value(t, Docs_ManualAddress("sound#the-mixer-buses"), "/manual/sound/#the-mixer-buses")
	testing.expect_value(t, Docs_URL("/manual/sound/"), "https://crossfireengine.io/manual/sound/")
	testing.expect_value(t, Docs_ManualSlug("README.md"), "")
	testing.expect_value(t, Docs_ManualSlug("scene_changes.md"), "scene-changes")
	free_all(context.temp_allocator)
}

// The bundled docs: the manual's pages, the API reference's (the website's areas and anchors)
@(test)
docs_library_reads_the_manual_and_the_api :: proc(t: ^testing.T) {
	table := EngineDocs_Load(ENGINE_DIR)
	if !testing.expect(t, table != nil, "the engine's docs") do return
	best := time.Duration(max(i64))
	lib: ^DocsLibrary
	for run in 0 ..< TIMING_RUNS {
		if lib != nil do DocsLibrary_Destroy(lib)
		lib = DocsLibrary_Build(DOCS_MANUAL_SOURCE, table)
		best = min(best, lib.took)
		_ = run
	}
	defer DocsLibrary_Destroy(lib)
	log.infof("docs: %d pages read in %v (best of %d)", len(lib.pages), best, TIMING_RUNS)
	// About 0.45 s in a debug build alone; generous: the UI suites beside it took it past 5 s
	testing.expectf(t, best < 15 * time.Second, "reading the docs took %v", best)

	index := DocsLibrary_Find(lib, "/manual/")
	if testing.expect(t, index != nil, "the manual's contents") do testing.expect_value(t, index.title, "Crossfire Editor user manual")
	testing.expect(t, lib.pages[0].address == "/manual/", "the manual first, in reading order")
	physics := DocsLibrary_Find(lib, "/manual/physics/#joints")
	testing.expect(t, physics != nil && DocsPage_HasAnchor(physics, "joints"), "a manual page and its anchor")
	// The API: the index and every area, each declaration a heading with the website's anchor
	testing.expect(t, DocsLibrary_Find(lib, "/api/") != nil, "the API's index")
	for area in ENGINE_API_AREAS {
		testing.expectf(t, DocsLibrary_Find(lib, fmt.tprintf("/api/%s/", area.slug)) != nil, "the area %s", area.slug)
	}
	camera := DocsLibrary_Find(lib, "/api/camera/")
	if testing.expect(t, camera != nil, "the camera's page") {
		testing.expect_value(t, camera.title, "Camera")
		testing.expect(t, DocsPage_HasAnchor(camera, "camera2d_follow") && DocsPage_HasAnchor(camera, "camera2d"), "declarations' anchors")
		testing.expect(t, DocsPage_HasAnchor(camera, "procedures") && DocsPage_HasAnchor(camera, "types"), "the sections")
	}
	for name, d in table.decls {
		address := Docs_EngineAddress(d)
		page, anchor := Docs_SplitAddress(address)
		p := DocsLibrary_Find(lib, page)
		testing.expectf(t, p != nil && DocsPage_HasAnchor(p, anchor), "%s's entry %s", name, address)
	}
	// Inline code naming a declaration links to it
	follow := DocsLibrary_Find(lib, "/api/camera/")
	linked := false
	if follow != nil do for b in follow.doc.blocks {
		for s in b.spans do if s.code && s.link == "#camera2d_follow" do linked = true
		for item in b.items do for s in item.spans do if s.code && s.link == "#camera2d_follow" do linked = true
	}
	testing.expect(t, linked, "`Camera2D_Follow` in the camera's page links to its entry")
	free_all(context.temp_allocator)
}

// Every node kind has its guide, every asset kind and bottom tab its page, every place F1 knows
@(test)
docs_every_kind_has_a_page :: proc(t: ^testing.T) {
	table := EngineDocs_Load(ENGINE_DIR)
	lib := DocsLibrary_Build(DOCS_MANUAL_SOURCE, table)
	defer DocsLibrary_Destroy(lib)
	exists :: proc(t: ^testing.T, lib: ^DocsLibrary, address, what: string) {
		page, anchor := Docs_SplitAddress(address)
		p := DocsLibrary_Find(lib, page)
		testing.expectf(t, p != nil && (anchor == "" || DocsPage_HasAnchor(p, anchor)), "%s has its page: %s", what, address)
	}
	for kind in NodeKind do exists(t, lib, Docs_NodeKindAddress(kind), fmt.tprintf("the node kind %v", kind))
	for kind in AssetKind do exists(t, lib, Docs_AssetKindAddress(kind), fmt.tprintf("the asset kind %v", kind))
	for tab in BottomTab do exists(t, lib, Docs_ManualAddress(DOCS_BOTTOM_TAB_PAGES[tab]), fmt.tprintf("the bottom tab %v", tab))
	for page in ([]string{DOCS_SCENE_PAGE, DOCS_SCRIPT_PAGE, DOCS_CODE_PAGE, DOCS_VIEWPORT_PAGE, DOCS_SCENE_TREE_PAGE, DOCS_INSPECTOR_PAGE, DOCS_BROWSER_PAGE}) {
		exists(t, lib, Docs_ManualAddress(page), page)
	}
	testing.expect_value(t, Docs_NodeKindAddress(.AnimatedSprite), "/manual/nodes-graphics/#animatedsprite")
	free_all(context.temp_allocator)
}

// Types and names in code: node types to their guides, the rest to the API
@(test)
docs_symbols_find_their_pages :: proc(t: ^testing.T) {
	table := EngineDocs_Load(ENGINE_DIR)
	testing.expect_value(t, Docs_TypeAddress("^e.Sprite", "e", table), "/manual/nodes-graphics/#sprite")
	testing.expect_value(t, Docs_TypeAddress("^e.Camera2D", "e", table), "/manual/nodes-scene/#camera")
	testing.expect_value(t, Docs_TypeAddress("[]^e.Area", "e", table), "/manual/nodes-physics/#area")
	testing.expect_value(t, Docs_TypeAddress("e.Script", "e", table), "/manual/scripts/")
	testing.expect_value(t, Docs_TypeAddress("e.TextureAsset", "e", table), "/api/assets-and-import/#textureasset")
	testing.expect_value(t, Docs_TypeAddress("crossfire.Sprite", "crossfire", table), "/manual/nodes-graphics/#sprite")
	testing.expect_value(t, Docs_TypeAddress("^Hero", "e", table), "")
	// The project's own node types go to their base kind's guide, through what they embed
	own := make(map[string]string, context.temp_allocator)
	own["Door"], own["BigDoor"], own["Hero"], own["Loop"] = "e.Sprite", "Door", "e.Script", "Loop"
	testing.expect_value(t, Docs_TypeAddress("^Door", "e", table, own), "/manual/nodes-graphics/#sprite")
	testing.expect_value(t, Docs_TypeAddress("[]^BigDoor", "e", table, own), "/manual/nodes-graphics/#sprite")
	testing.expect_value(t, Docs_TypeAddress("^Hero", "e", table, own), "/manual/scripts/")
	testing.expect_value(t, Docs_TypeAddress("Loop", "e", table, own), "")
	testing.expect_value(t, Docs_TypeAddress("Window", "e", table, own), "")
	testing.expect_value(t, Docs_TypeAddress("f32", "e", table), "")
	testing.expect_value(t, Docs_EngineNameAddress("Camera2D_Follow", table), "/api/camera/#camera2d_follow")
	testing.expect_value(t, Docs_EngineNameAddress("NoSuchThing", table), "")
	free_all(context.temp_allocator)
}

// Search: titles first, then headings (an API entry named exactly first), then text
@(test)
docs_search_titles_headings_text :: proc(t: ^testing.T) {
	table := EngineDocs_Load(ENGINE_DIR)
	lib := DocsLibrary_Build(DOCS_MANUAL_SOURCE, table)
	defer DocsLibrary_Destroy(lib)
	start := time.tick_now()
	hits := Docs_Search(lib, "physics")
	log.infof("docs: searching 'physics' took %v (%d hits)", time.tick_since(start), len(hits))
	if testing.expect(t, len(hits) > 0, "hits") {
		testing.expectf(t, lib.pages[hits[0].page].address == "/manual/physics/" && hits[0].anchor == "", "the page titled Physics first: %s", lib.pages[hits[0].page].address)
	}
	exact := Docs_Search(lib, "camera2d_follow")
	if testing.expect(t, len(exact) > 0, "an API name") {
		testing.expect_value(t, exact[0].anchor, "camera2d_follow")
		testing.expect_value(t, lib.pages[exact[0].page].address, "/api/camera/")
	}
	words := Docs_Search(lib, "one-way platform")
	testing.expect(t, len(words) > 0 && words[0].heading != "", "every word in a heading or its text")
	if len(words) > 0 do testing.expectf(t, strings.contains(strings.to_lower(words[0].snippet, context.temp_allocator), "one-way") || words[0].heading != "", "a snippet: %s", words[0].snippet)
	testing.expect_value(t, len(Docs_Search(lib, "")), 0)
	testing.expect_value(t, len(Docs_Search(lib, "zzqqxx")), 0)
	testing.expect(t, len(Docs_Search(lib, "e")) <= DOCS_SEARCH_MAX, "at most DOCS_SEARCH_MAX")
	free_all(context.temp_allocator)
}

