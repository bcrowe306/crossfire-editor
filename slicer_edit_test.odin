package crossfire_editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import e "engine:."
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

// The sprite sheet slicer: grid math, sprites found on the demo's sheets and an uneven one,
// animations made, an asset, applied, added, undone, saved; its settings remembered

@(private="file")
send :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
slicerProject :: proc(t: ^testing.T, name: string) -> (state: State, dir: string) {
	dir = joinPath(testTempBase(), fmt.tprintf("crossfire_test_slicer_%s", name), allocator = context.temp_allocator)
	removeAll(dir)
	os.make_directory_all(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state = State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	testing.expect_value(t, Project_Save(&state.project), "")
	return
}

// Grid math: cells under points (margins, gaps, offsets), rows, evening out, what's made
@(test)
slicer_grid_math :: proc(t: ^testing.T) {
	settings := SlicerSettings{mode = .Grid, grid = {mode = .Size, cellSize = {16, 16}, margin = 1, spacing = 2, offset = {4, 0}}}
	size := [2]f32{4 + 1 + 16 + 2 + 16 + 2 + 16 + 1, 1 + 16 + 2 + 16 + 1}
	testing.expect_value(t, Slicer_CellCount(&settings, size), 6)
	testing.expect_value(t, Slicer_CellAt(&settings, size, {6, 2}), 0)
	testing.expect_value(t, Slicer_CellAt(&settings, size, {4 + 1 + 18 + 3, 20}), 4)
	testing.expect_value(t, Slicer_CellAt(&settings, size, {4 + 1 + 16 + 1, 5}), -1)
	testing.expect_value(t, Slicer_CellAt(&settings, size, {2, 5}), -1)
	testing.expect_value(t, Slicer_CellRect(&settings, size, 4), sdl.FRect{4 + 1 + 18, 1 + 18, 16, 16})
	testing.expect(t, slice.equal(Slicer_RowOf(&settings, size, 4), []int{3, 4, 5}), "the second row")
	testing.expect_value(t, len(Slicer_Rows(&settings, size)), 2)

	// Found sprites: rows by vertical overlap, the smallest box under a point
	found := SlicerSettings{mode = .Auto}
	defer delete(found.found)
	append(&found.found, sdl.FRect{0, 4, 10, 12}, sdl.FRect{14, 0, 8, 16}, sdl.FRect{2, 30, 12, 10}, sdl.FRect{3, 32, 4, 4})
	testing.expect_value(t, Slicer_CellAt(&found, {}, {4, 33}), 3)
	testing.expect(t, slice.equal(Slicer_RowOf(&found, {}, 0), []int{0, 1}), "the first row")
	testing.expect_value(t, len(Slicer_Rows(&found, {})), 2)

	// Evened out: the largest size, the bottom middle kept, inside the sheet
	rects := []sdl.FRect{{0, 4, 10, 12}, {14, 0, 8, 16}}
	Slicer_EvenOut(rects, {30, 16})
	testing.expect_value(t, rects[0], sdl.FRect{0, 0, 10, 16})
	testing.expect_value(t, rects[1], sdl.FRect{13, 0, 10, 16})

	// What's made: a run of grid cells is the grid and a range; anything else rectangles
	append(&settings.animations, SliceAnimation{name = strings.clone("run"), fps = 10, loop = true})
	append(&settings.animations[0].frames, 3, 4, 5)
	append(&settings.animations, SliceAnimation{name = strings.clone("odd"), fps = 6})
	append(&settings.animations[1].frames, 5, 0, 99)
	append(&settings.animations, SliceAnimation{name = strings.clone("empty")})
	defer SlicerSettings_Destroy(&settings)
	defs := Slicer_AnimationDefs(&settings, "assets/sheet.png", size)
	defer {
		for &d in defs do AnimationDef_Destroy(&d)
		delete(defs)
	}
	if !testing.expect_value(t, len(defs), 2) do return
	testing.expect(t, defs[0].grid == settings.grid && defs[0].start == 3 && defs[0].end == 5 && len(defs[0].rects) == 0 && defs[0].loop, "run: the grid and a range")
	testing.expect(t, len(defs[1].rects) == 2 && defs[1].rects[0] == Slicer_CellRect(&settings, size, 5) && defs[1].start == 0 && defs[1].end == 1, "odd: two rectangles (the missing cell left out)")
	testing.expect_value(t, defs[1].sheet, "assets/sheet.png")
	testing.expect_value(t, AnimEdit_Cells("", defs[1]), 2)
}

// Sprites found on the demo's Legacy-Fantasy sheets and on a generated sheet of uneven sprites
@(test)
slicer_finds_sprites_on_sheets :: proc(t: ^testing.T) {
	// The snail's walk: 8 frames on a 384 x 32 strip
	snail, note := Slicer_FindSprites("examples/demo_project/assets/mobs/snail_walk.png", {threshold = 128, mergeDistance = 2, minSize = 4})
	defer { delete(snail); delete(note) }
	testing.expectf(t, len(snail) == 8, "the snail's 8 frames (%s)", note)
	for r, i in snail do testing.expectf(t, r.x >= f32(i * 48) && r.x + r.w <= f32((i + 1) * 48) && r.h <= 32, "frame %d inside its 48 px cell: %v", i, r)
	testing.expect(t, strings.contains(note, "8 sprites"), note)

	// A generated sheet: uneven sprites in two rows, one with a loose part, a speck, on magenta
	dir := joinPath(testTempBase(), "crossfire_test_slicer_uneven", allocator = context.temp_allocator)
	removeAll(dir)
	os.make_directory_all(dir)
	defer removeAll(dir)
	w, h := 96, 64
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	fill :: proc(pixels: []u8, w, x, y, rw, rh: int, c: [4]u8) {
		c := c
		for yy in y ..< y + rh do for xx in x ..< x + rw do copy(pixels[(yy * w + xx) * 4:][:4], c[:])
	}
	fill(pixels, w, 0, 0, w, h, {255, 0, 255, 255})
	red := [4]u8{200, 40, 40, 255}
	fill(pixels, w, 2, 6, 12, 20, red)
	fill(pixels, w, 15, 10, 3, 6, red) // a sword a pixel from its hand
	fill(pixels, w, 30, 2, 18, 24, red)
	fill(pixels, w, 60, 12, 10, 14, red)
	fill(pixels, w, 80, 2, 1, 1, red) // a speck
	fill(pixels, w, 6, 36, 30, 22, red)
	fill(pixels, w, 50, 40, 14, 20, red)
	path := joinPath(dir, "uneven.png", allocator = context.temp_allocator)
	testing.expect(t, stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(w), i32(h), 4, raw_data(pixels), i32(w * 4)) != 0, "written")
	found, foundNote := Slicer_FindSprites(path, {threshold = 128, mergeDistance = 2, minSize = 4})
	defer { delete(found); delete(foundNote) }
	expected := []sdl.FRect{{2, 6, 16, 20}, {30, 2, 18, 24}, {60, 12, 10, 14}, {6, 36, 30, 22}, {50, 40, 14, 20}}
	testing.expectf(t, slice.equal(found, expected), "found %v (%s)", found, foundNote)
	testing.expect(t, strings.contains(foundNote, "background #ff00ff"), foundNote)

	// Through the tab: auto-detect on the small sheet answers at once, the sword merged
	state, projectDir := slicerProject(t, "detect")
	defer { State_Destroy(&state); removeAll(projectDir) }
	at, problem := Project_ImportAsset(&state.project, path)
	testing.expect_value(t, problem, "")
	if at < 0 do return
	send(&state, Slicer_Opened(state.project.assets[at].path))
	send(&state, Slicer_Changed{op = .Mode, text = "Auto"})
	tab := Slicer_Shown(&state)
	if !testing.expect(t, tab != nil, "the tab shows") do return
	testing.expect_value(t, len(tab.settings.found), 5)
	send(&state, Slicer_Number_Changed{.Merge, 0})
	send(&state, Slicer_Changed{op = .Detect})
	testing.expect_value(t, len(Slicer_Shown(&state).settings.found), 6)
	free_all(context.temp_allocator)
}

// A big sheet finds its sprites on a worker; the time it takes there
@(test)
slicer_big_sheets_are_fast :: proc(t: ^testing.T) {
	w, h := 4096, 4096
	pixels := make([]u8, w * h * 4)
	defer delete(pixels)
	for row in 0 ..< 32 do for column in 0 ..< 32 {
		x0, y0 := column * 128 + 8 + column % 9, row * 128 + 4 + row % 7
		for y in y0 ..< y0 + 90 + row % 20 do for x in x0 ..< x0 + 70 + column % 30 do pixels[(y * w + x) * 4 + 3] = 255
	}
	best := max(f64)
	count := 0
	for _ in 0 ..< TIMING_RUNS {
		start := time.tick_now()
		found := e.Sheet_FindSprites(pixels, w, h)
		best = min(best, time.duration_milliseconds(time.tick_since(start)))
		count = len(found)
		delete(found)
	}
	fmt.printfln("Slicer: sprites found on a 4096 x 4096 sheet in %.0f ms (best of %d)", best, TIMING_RUNS)
	testing.expect_value(t, count, 32 * 32)
	testing.expectf(t, best < 5000, "4096 x 4096 in %.0f ms", best)
}

// Animations named from picked frames, an asset made and updated, applied to a sprite, added to
// the scene, each undone and redone; saved, read back, and in scripts/assets.odin
@(test)
slicer_makes_animations_applies_and_undoes :: proc(t: ^testing.T) {
	state, dir := slicerProject(t, "make")
	defer { State_Destroy(&state); removeAll(dir) }
	// 320 x 100: four balloons
	at, problem := Project_ImportAsset(&state.project, "tests/fixtures/ui_project/assets/balloons.png")
	testing.expect_value(t, problem, "")
	if at < 0 do return
	image := state.project.assets[at].path
	send(&state, Slicer_Opened(image))
	testing.expect_value(t, state.slicer.shown, 1)
	testing.expect_value(t, state.codeTab, 0)
	send(&state, Slicer_Number_Changed{.Columns, 4})
	tab := Slicer_Shown(&state)
	testing.expect_value(t, Slicer_CellCount(&tab.settings, Slicer_SheetSize(&state, tab)), 4)

	// Picks: a click, Shift+click the run, Ctrl+click takes one away and adds it back at the end
	send(&state, Slicer_Changed{op = .Cell_Clicked, index = 0})
	send(&state, Slicer_Changed{op = .Cell_Clicked, index = 3, flag = true})
	testing.expect(t, slice.equal(Slicer_Shown(&state).selection[:], []int{0, 1, 2, 3}), "the run")
	send(&state, Slicer_Changed{op = .Animation_Added})
	send(&state, Slicer_Changed{op = .Name_Typed, text = "float", id = 1})
	send(&state, Slicer_Number_Changed{.FPS, 12})
	tab = Slicer_Shown(&state)
	testing.expect(t, len(tab.settings.animations) == 1 && tab.settings.animations[0].name == "float" && tab.settings.animations[0].fps == 12, "float, 12 fps")
	send(&state, Slicer_Changed{op = .Cell_Clicked, index = 3})
	send(&state, Slicer_Changed{op = .Cell_Clicked, index = 1, number = 1})
	send(&state, Slicer_Changed{op = .Animation_Added, text = "pop"})
	send(&state, Slicer_Changed{op = .Loop, flag = false})
	send(&state, Slicer_Changed{op = .Durations, flag = true})
	send(&state, Slicer_Duration_Changed{1, 250})
	tab = Slicer_Shown(&state)
	pop := tab.settings.animations[1]
	testing.expect(t, slice.equal(pop.frames[:], []int{3, 1}) && !pop.loop && len(pop.durations) == 2 && pop.durations[1] == 0.25, "pop: 3 then 1, 250 ms")
	// A frame moved earlier: its time goes with it
	send(&state, Slicer_Changed{op = .Frame_Picked, index = 1})
	send(&state, Slicer_Changed{op = .Frame_Moved, number = -1})
	pop = Slicer_Shown(&state).settings.animations[1]
	testing.expect(t, slice.equal(pop.frames[:], []int{1, 3}) && pop.durations[0] == 0.25, "moved with its time")
	// The slicer's own edits aren't undo steps
	testing.expect_value(t, len(state.history.undo), 0)

	// Create animation asset: in the project (written by Save), a project step
	send(&state, Slicer_Asset_Created{})
	testing.expect_value(t, len(state.project.animationSets), 1)
	set := state.project.animationSets[0]
	testing.expect_value(t, set.path, "animations/balloons.anim.xml")
	testing.expect(t, set.stepMade && len(set.animations) == 2, "made by the step")
	testing.expect(t, set.animations[0].grid.columns == 4 && set.animations[0].start == 0 && set.animations[0].end == 3 && len(set.animations[0].rects) == 0, "float: the grid's run")
	testing.expect(t, len(set.animations[1].rects) == 2 && set.animations[1].rects[0] == sdl.FRect{80, 0, 80, 100}, "pop: rectangles")
	assetCount := len(state.project.assets)
	testing.expect_value(t, Slicer_Shown(&state).settings.asset, "animations/balloons.anim.xml")
	// The constants scripts get
	names := make([dynamic]string, context.temp_allocator)
	for c in Scripts_Constants(&state.project) do append(&names, c.name)
	testing.expect(t, slice.contains(names[:], "ANIM_BALLOONS_FLOAT") && slice.contains(names[:], "ANIM_BALLOONS_POP") && slice.contains(names[:], "ANIMATION_BALLOONS"), "ANIM_ constants")
	send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.animationSets), 0)
	testing.expect_value(t, len(state.project.assets), assetCount - 1)
	send(&state, Action.Redo)
	testing.expect_value(t, len(state.project.animationSets), 1)
	testing.expect_value(t, len(state.project.assets), assetCount)

	// Updated: the same asset, a project step undone by file
	send(&state, Slicer_Changed{op = .Animation_Selected, index = 1})
	send(&state, Slicer_Changed{op = .Animation_Removed})
	send(&state, Slicer_Asset_Created{})
	testing.expect_value(t, len(state.project.animationSets), 1)
	testing.expect_value(t, len(state.project.animationSets[0].animations), 1)
	send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.animationSets[0].animations), 2)

	// Apply to sprite: nothing selected, nothing happens; the selected AnimatedSprite gets the asset
	scene := &state.project.scenes[0]
	send(&state, Slicer_Applied{})
	sprite := Scene_InsertNode(scene, "Hero", .AnimatedSprite, -1)
	state.selectedNode = sprite
	undos := len(state.history.undo)
	send(&state, Slicer_Applied{})
	testing.expect_value(t, state.project.scenes[0].nodes[sprite].animationSet, "animations/balloons.anim.xml")
	testing.expect_value(t, len(state.history.undo), undos + 1)
	send(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[0].nodes[sprite].animationSet, "")
	// Or its own animations (the tab's: float only now)
	send(&state, Slicer_Changed{op = .Use_Asset, flag = false})
	send(&state, Slicer_Applied{})
	node := &state.project.scenes[0].nodes[sprite]
	testing.expect(t, node.animationSet == "" && len(node.animations) == 1 && node.animations[0].name == "float" && node.animations[0].sheet == image, "its own animations")

	// Add to scene: a new AnimatedSprite, selected; undone
	nodes := len(state.project.scenes[0].nodes)
	send(&state, Slicer_Added_To_Scene{})
	testing.expect_value(t, len(state.project.scenes[0].nodes), nodes + 1)
	added := state.project.scenes[0].nodes[state.selectedNode]
	testing.expect(t, added.kind == .AnimatedSprite && added.name == "Balloons" && len(added.animations) == 1, "Balloons, playing float")
	send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.scenes[0].nodes), nodes)

	// Saved: the asset's file, its rectangles read back by the engine
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, loadProblem := Project_LoadAnimationSet(state.project.rootPath, "animations/balloons.anim.xml")
	defer AnimationSetDef_Destroy(&loaded)
	testing.expect_value(t, loadProblem, "")
	testing.expect(t, AnimationSetDef_Equal(loaded, state.project.animationSets[0]), "read back as made")
	text := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(text, `columns="4"`), "the sprite's animation on the grid")

	// The tab picked: a scene tab hides it, the slicer's tab shows it again, Close closes it
	send(&state, Scene_Tab_Changed(0))
	testing.expect_value(t, state.slicer.shown, 0)
	send(&state, Slicer_Tab_Selected(0))
	testing.expect_value(t, state.slicer.shown, 1)
	send(&state, Slicer_Tab_Closed(0))
	testing.expect(t, state.slicer.shown == 0 && len(state.slicer.tabs) == 0, "closed")
	free_all(context.temp_allocator)
}

// The tab's settings in .editor/slicer.ini: written when they change, other images' kept, read
// back when the tab opens again
@(test)
slicer_settings_persist :: proc(t: ^testing.T) {
	state, dir := slicerProject(t, "persist")
	defer { State_Destroy(&state); removeAll(dir) }
	at, problem := Project_ImportAsset(&state.project, "tests/fixtures/ui_project/assets/balloons.png")
	testing.expect_value(t, problem, "")
	light, problem2 := Project_ImportAsset(&state.project, "tests/fixtures/ui_project/assets/light.png")
	testing.expect_value(t, problem2, "")
	if at < 0 || light < 0 do return
	image, lightImage := state.project.assets[at].path, state.project.assets[light].path

	// Another image first: its section stays
	send(&state, Slicer_Opened(lightImage))
	send(&state, Slicer_Number_Changed{.Columns, 3})
	send(&state, Slicer_Opened(image))
	testing.expect_value(t, state.slicer.shown, 2)
	send(&state, Slicer_Changed{op = .Grid_Mode, text = "Size"})
	send(&state, Slicer_Number_Changed{.Cell_Width, 80})
	send(&state, Slicer_Number_Changed{.Cell_Height, 100})
	send(&state, Slicer_Number_Changed{.Offset_Y, 0})
	send(&state, Slicer_Number_Changed{.Margin, 0})
	send(&state, Slicer_Changed{op = .Select_All})
	send(&state, Slicer_Changed{op = .Reverse_Selection})
	send(&state, Slicer_Changed{op = .Animation_Added, text = "back"})
	send(&state, Slicer_Changed{op = .Name_Typed, text = "back to front", id = 1})
	send(&state, Slicer_Changed{op = .Play_Mode, text = "PingPong"})
	file, err := os.read_entire_file(joinPath(state.project.rootPath, SLICER_FILE, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, err == nil, "written")
	text := string(file)
	testing.expect(t, strings.contains(text, fmt.tprintf("[%s]", lightImage)) && strings.contains(text, fmt.tprintf("[%s]", image)), text)
	testing.expect(t, strings.contains(text, "anim = 8 1 PingPong | 3 2 1 0 | | back to front"), text)

	// Closed and opened again: as it was
	send(&state, Slicer_Tab_Closed(1))
	send(&state, Slicer_Opened(image))
	tab := Slicer_Shown(&state)
	if !testing.expect(t, tab != nil, "open") do return
	testing.expect(t, tab.settings.grid.mode == .Size && tab.settings.grid.cellSize == {80, 100}, "its grid")
	testing.expect(t, len(tab.settings.animations) == 1 && tab.settings.animations[0].name == "back to front" && tab.settings.animations[0].playMode == .PingPong, "its animation")
	testing.expect(t, slice.equal(tab.settings.animations[0].frames[:], []int{3, 2, 1, 0}), "its frames")
	other, found := Slicer_Load(state.project.rootPath, lightImage)
	defer SlicerSettings_Destroy(&other)
	testing.expect(t, found && other.grid.columns == 3, "the other image's")

	// Names that can't be: refused while typed
	testing.expect(t, Slicer_NameProblem(tab.settings.animations[:], -1, "back to front") != "", "taken")
	testing.expect(t, Slicer_NameProblem(tab.settings.animations[:], 0, " x") != "", "spaces")
	testing.expect(t, Slicer_NameProblem(tab.settings.animations[:], 0, "a|b") != "", "a bar")
	// Format and parse agree; a section replaced keeps the rest
	again, ok := Slicer_Parse(Slicer_Format(image, &tab.settings), image)
	defer SlicerSettings_Destroy(&again)
	testing.expect(t, ok && again.grid == tab.settings.grid && len(again.animations) == 1, "round trip")
	merged := Slicer_ReplaceSection("[a]\nmode = Grid\n[b]\nmode = Auto\n", "a", "[a]\nmode = Auto\n")
	testing.expect_value(t, merged, "[a]\nmode = Auto\n[b]\nmode = Auto\n")
	free_all(context.temp_allocator)
}
