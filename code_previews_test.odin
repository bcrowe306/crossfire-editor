package crossfire_editor

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"

// What a string literal or tag at a column names
@(test)
code_previews_literal_text :: proc(t: ^testing.T) {
	line := "\tsprite: e.TextureAsset `export:\"default=assets/ship.png min=1\"`, // \"assets/no.png\""
	at := strings.index(line, "ship")
	text, ok := Preview_LiteralAt(line, at)
	testing.expect(t, ok && text == "assets/ship.png", "a tag's default")
	text, ok = Preview_LiteralAt(line, strings.index(line, "min="))
	testing.expect(t, ok && text == "1", "another option of the tag")
	_, ok = Preview_LiteralAt(line, strings.index(line, "no.png"))
	testing.expect(t, !ok, "not in a comment")
	_, ok = Preview_LiteralAt(line, strings.index(line, "sprite"))
	testing.expect(t, !ok, "not outside a literal")
	call := `e.Game_ChangeScene(game, "Forest\"Scene")`
	text, ok = Preview_LiteralAt(call, strings.index(call, "Forest") + 2)
	testing.expect(t, ok && text == `Forest\"Scene`, "an escaped quote stays inside")
}

// Thumbnails fit without growing; a strip puts cells side by side at one height
@(test)
code_previews_fit_and_strip :: proc(t: ^testing.T) {
	big := make([]u8, 400 * 100 * 4, context.temp_allocator)
	_, w, h := Preview_Fit(big, 400, 100, 320, 160)
	testing.expect_value(t, [2]int{w, h}, [2]int{320, 80})
	small := make([]u8, 16 * 16 * 4, context.temp_allocator)
	small[0] = 200
	out, w2, h2 := Preview_Fit(small, 16, 16, 320, 160)
	testing.expect_value(t, [2]int{w2, h2}, [2]int{16, 16})
	testing.expect_value(t, out[0], u8(200))
	// A 4x2 sheet of 8x8 cells, cell 1 red: two cells at 16 px tall, 2 px apart
	sheet := make([]u8, 32 * 16 * 4, context.temp_allocator)
	for y in 0 ..< 8 do for x in 8 ..< 16 do sheet[(y * 32 + x) * 4] = 255
	strip, sw, sh := Preview_Strip(sheet, 32, 16, {{0, 0, 8, 8}, {8, 0, 8, 8}}, 16)
	testing.expect_value(t, [2]int{sw, sh}, [2]int{34, 16})
	testing.expect_value(t, strip[(5 * 34 + 1) * 4], u8(0))
	testing.expect_value(t, strip[(5 * 34 + 20) * 4], u8(255))
	free_all(context.temp_allocator)
}

// Each kind of hover on the demo, and how long it takes cold (made) and warm (kept)
@(test)
code_previews_of_every_kind :: proc(t: ^testing.T) {
	// Thumbnails and fonts: SDL_ttf isn't thread-safe; the previews are package state
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	defer Preview_Destroy()
	project, message, _ := Project_Load(DEMO_PROJECT)
	testing.expect_value(t, message, "")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	defer State_Destroy(&state)
	constants := CodeProviders_Constants(&state)
	Kind :: struct { name: string, images, widgets: int, text: string }
	kinds := []Kind{
		{"TEXTURE_COIN", 1, 0, "coin.png: "},
		{"TEXTURE_HERO", 1, 0, "frames"},
		{"SOUND_JUMP", 0, 1, "jump.ogg: a sound, 0:"},
		{"MUSIC_TITLE", 0, 1, "music (streamed)"},
		{"FONT_PIXELIFYSANS", 1, 0, "PixelifySans.ttf: a font"},
		{"COMPONENT_BEE", 1, 0, "Component bee"},
		{"ANIM_BEE_FLY", 1, 0, "Animation \"fly\""},
		{"ANIMATION_BOAR_RUN", 1, 0, "boar_run.aseprite: "},
		{"DIALOGUE_STORY", 0, 0, "story.dialogue.xml, node"},
		{"SCENE_FOREST_SCENE", 0, 0, "Scene ForestScene"},
	}
	for k in kinds {
		c := Scripts_FindConstant(constants, k.name)
		if !testing.expectf(t, c != nil, "the demo has %s", k.name) do continue
		// The first (cold) and the best warm one of TIMING_RUNS
		times := [2]time.Duration{0, time.Duration(max(i64))}
		blocks: [dynamic]ce.Hover_Block
		for round in 0 ..= TIMING_RUNS {
			out := ce.Hover_Content{blocks = make([dynamic]ce.Hover_Block, context.temp_allocator)}
			start := time.tick_now()
			CodePreviews_Constant(&state, c, &out)
			took := time.tick_since(start)
			if round == 0 do times[0] = took
			else do times[1] = min(times[1], took)
			blocks = out.blocks
		}
		images, widgets := 0, 0
		text := strings.builder_make(context.temp_allocator)
		for b in blocks {
			switch v in b {
			case ce.Hover_Image:
				images += 1
				testing.expectf(t, v.width > 0 && v.height > 0 && v.height <= PREVIEW_THUMB && len(v.pixels) == v.width * v.height * 4, "%s: a picture that fits (%dx%d)", k.name, v.width, v.height)
				testing.expectf(t, slice.any_of_proc(v.pixels, proc(b: u8) -> bool { return b != 0 }), "%s: a picture that isn't empty", k.name)
			case ce.Hover_Widget:
				widgets += 1
				testing.expect(t, v.click != nil && v.draw != nil, "a button")
			case ce.Hover_Text:
				strings.write_string(&text, v.text)
			}
		}
		testing.expectf(t, images == k.images && widgets == k.widgets, "%s: %d pictures, %d widgets (%d, %d expected)", k.name, images, widgets, k.images, k.widgets)
		testing.expectf(t, strings.contains(strings.to_string(text), k.text), "%s says %q: %s", k.name, k.text, strings.to_string(text))
		log.infof("hover preview %s: %v cold, %v warm", k.name, times[0], times[1])
		testing.expectf(t, times[1] < 10 * time.Millisecond, "%s: a warm hover is quick (%v)", k.name, times[1])
	}
	// The play button's click leaves the request for the code view
	out := ce.Hover_Content{blocks = make([dynamic]ce.Hover_Block, context.temp_allocator)}
	CodePreviews_Constant(&state, Scripts_FindConstant(constants, "SOUND_JUMP"), &out)
	for b in out.blocks do if w, ok := b.(ce.Hover_Widget); ok do testing.expect(t, w.click(4, 4, w.data), "the click is taken")
	request, has := CodePreviews_TakeAudio()
	testing.expect(t, has && request.play && request.path == "assets/sfx/jump.ogg", "play jump.ogg")
	_, has = CodePreviews_TakeAudio()
	testing.expect(t, !has, "once")

	// A literal naming an asset or a scene
	b := cebuf.buffer_init()
	defer cebuf.buffer_destroy(&b)
	cebuf.buffer_set_text(&b, "x := \"assets/items/coin.png\"\ny := \"ForestScene\"\nz := \"nothing\"\n")
	doc := ce.Provider_Document{path = "x.odin", buffer = &b}
	for line, i in ([]int{0, 1}) {
		lit := ce.Hover_Content{blocks = make([dynamic]ce.Hover_Block, context.temp_allocator)}
		testing.expectf(t, CodePreviews_Literal(&state, doc, {line, 8}, &lit) && len(lit.blocks) > 0, "literal %d previews", i)
	}
	none := ce.Hover_Content{blocks = make([dynamic]ce.Hover_Block, context.temp_allocator)}
	testing.expect(t, !CodePreviews_Literal(&state, doc, {2, 8}, &none), "a string naming nothing")
	free_all(context.temp_allocator)
}

// The engine's API areas are the website's (scripts/api-groups.json), when it's checked out beside
@(test)
engine_api_areas_match_the_website :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("../crossfire_astro/scripts/api-groups.json", context.temp_allocator)
	if err != nil {
		log.info("the website isn't checked out beside the editor: skipped")
		return
	}
	Groups :: struct { areas: []struct { slug, title, description: string, files: []string } }
	groups: Groups
	if !testing.expect(t, json.unmarshal(data, &groups, allocator = context.temp_allocator) == nil, "the website's areas parse") do return
	testing.expect_value(t, len(ENGINE_API_AREAS), len(groups.areas))
	for area, i in groups.areas {
		if i >= len(ENGINE_API_AREAS) do break
		mine := ENGINE_API_AREAS[i]
		testing.expectf(t, mine.slug == area.slug && mine.title == area.title && mine.description == area.description && slice.equal(mine.files, area.files), "area %s matches the website's (update ENGINE_API_AREAS in engine_docs.odin)", area.slug)
	}
	free_all(context.temp_allocator)
}
