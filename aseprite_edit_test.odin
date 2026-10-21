package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import e "engine:."

// Aseprite files in the editor: imported as images, read for the preview, drawn by the viewport,
// and drawn again with their new pixels once saved over

@(test)
aseprite_files_are_images_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_aseprite"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Art", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Art"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")

	// Imported as an image
	kind, known := AssetKindForPath("Hero.ASEPRITE")
	testing.expect(t, known && kind == .Image, ".aseprite is an image")
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/tags3.aseprite")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	path := state.project.assets[index].path
	testing.expect_value(t, state.project.assets[index].kind, AssetKind.Image)

	// Read for the preview
	ase := AsepriteEdit_File(root, path)
	testing.expect(t, ase != nil, "parsed")
	if ase == nil do return
	summary := AsepriteEdit_Summary(ase)
	testing.expectf(t, strings.contains(summary, "4 x 4") && strings.contains(summary, "12 frames") && strings.contains(summary, "3 tags"), "summary: %s", summary)
	testing.expect_value(t, AsepriteEdit_File(root, path), ase)
	pixels, w, h, ok := Image_LoadRGBA(joinPath(root, path, allocator = context.temp_allocator))
	testing.expect(t, ok && w == 4 && h == 4 && len(pixels) == 64, "its first frame, RGBA")

	// A Sprite showing it, 10x in the viewport: its pixels where the engine puts them
	scene := &state.project.scenes[0]
	sprite := Scene_InsertNode(scene, "Art", .Sprite, -1)
	delete(scene.nodes[sprite].texture)
	scene.nodes[sprite].texture = strings.clone(path)
	state.viewport = {center = {0, 0}, zoom = 10, size = {100, 100}}
	// The texel the viewport's middle shows, and one opaque texel's place on screen
	sample :: proc(t: ^testing.T, state: ^State, file: string, loc := #caller_location) {
		ase, err := e.Aseprite_Load(file)
		testing.expect_value(t, err, e.AsepriteError.None, loc = loc)
		if ase == nil do return
		defer e.Aseprite_Destroy(ase)
		frame := e.Aseprite_FramePixels(ase, 0, context.temp_allocator)
		rendered, ok := Preview_Render(state, {100, 100}, 1)
		testing.expect(t, ok, "rendered", loc = loc)
		if !ok do return
		checked := 0
		for y in 0..<4 do for x in 0..<4 {
			want := frame[(y * 4 + x) * 4:][:4]
			if want[3] != 255 do continue
			// The sprite is centered on the origin, the view's middle
			sx, sy := 50 + (x - 2) * 10 + 5, 50 + (y - 2) * 10 + 5
			got := rendered[(sy * 100 + sx) * 4:][:4]
			testing.expectf(t, got[0] == want[0] && got[1] == want[1] && got[2] == want[2], "texel (%d, %d): %v, want %v", x, y, got, want, loc = loc)
			checked += 1
		}
		testing.expect(t, checked > 0, "some opaque texels", loc = loc)
	}
	full := joinPath(root, path, allocator = context.temp_allocator)
	sample(t, &state, full)

	// Saved over (another 4 x 4 sprite): the viewport draws the new pixels, without a rebuild
	before := Preview_FrameKey(&state, {100, 100}, 1)
	time.sleep(600 * time.Millisecond)
	data, _ := os.read_entire_file("tests/fixtures/aseprite/bg-index-3.aseprite", context.temp_allocator)
	testing.expect(t, os.write_entire_file(full, data) == nil, "saved over")
	time.sleep(600 * time.Millisecond)
	testing.expect(t, Preview_FrameKey(&state, {100, 100}, 1) != before, "a new frame")
	sample(t, &state, full)
	// The preview's parse follows the file too
	testing.expect_value(t, len(AsepriteEdit_File(root, path).frames), 1)
	free_all(context.temp_allocator)
}
