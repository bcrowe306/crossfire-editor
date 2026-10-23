package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."

// Animation assets in the editor: made from a sprite's own animations, saved and loaded, edited in
// the Animation panel (project undo steps), Aseprite files' read only, drawn in the viewport, and
// in scripts/assets.odin

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
animation_assets_are_made_saved_edited_and_undone :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_animation_sets"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	sheet, problem := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/tags3.aseprite")
	testing.expect_value(t, problem, "")
	if sheet < 0 do return
	asePath := state.project.assets[sheet].path

	// A sprite with its own animations on a 4 x 4 frame sheet (the Aseprite file's first frame)
	scene := &state.project.scenes[0]
	hero := Scene_InsertNode(scene, "Hero", .AnimatedSprite, -1)
	state.selectedNode = hero
	node := &scene.nodes[hero]
	delete(node.animations[0].sheet)
	node.animations[0].sheet = strings.clone(asePath)
	node.animations[0].grid = {mode = .Cells, columns = 2, rows = 2}
	node.animations[0].durations = make([dynamic]f32)
	append(&node.animations[0].durations, 0.1, 0.2, 0.1, 0.3)

	// Saved as an asset it plays: its own animations go there
	sendTo(&state, Anim_Set_From_Node{})
	node = &state.project.scenes[0].nodes[hero]
	testing.expect_value(t, node.animationSet, "animations/hero.anim.xml")
	testing.expect_value(t, len(node.animations), 0)
	testing.expect_value(t, len(state.project.animationSets), 1)
	testing.expect(t, os.exists(joinPath(root, "animations/hero.anim.xml", allocator = context.temp_allocator)), "its file")
	src := AnimEdit_Source(&state)
	testing.expect(t, src.kind == .Set && len(src.animations^) == 1 && src.animations[0].grid.columns == 2 && src.animations[0].sheet == asePath, "the panel shows the asset")
	testing.expect_value(t, len(src.animations[0].durations), 4)
	// Undo: the sprite has its own animations again (the file stays, like components)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[0].nodes[hero].animationSet, "")
	testing.expect_value(t, len(state.project.scenes[0].nodes[hero].animations), 1)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, state.project.scenes[0].nodes[hero].animationSet, "animations/hero.anim.xml")

	// Edited in the panel: a project step, undone and redone
	sendTo(&state, Anim_Added{})
	sendTo(&state, Anim_Field_Changed{.Columns, 4})
	set := &state.project.animationSets[0]
	testing.expect(t, len(set.animations) == 2 && set.animations[1].grid.columns == 4 && set.animations[1].sheet == asePath && set.animations[0].grid.columns == 2, "edited: the new one on the same sheet")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.animationSets[0].animations[1].grid.columns, 2)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(state.project.animationSets[0].animations), 1)
	sendTo(&state, Action.Redo)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, len(state.project.animationSets[0].animations), 2)

	// Saved and opened again: the same set, the sprite still using it
	testing.expect_value(t, Project_Save(&state.project), "")
	xml := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `animations="animations/hero.anim.xml"`), xml)
	text, _ := os.read_entire_file(joinPath(root, "animations/hero.anim.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `durations="100 200 100 300"`), string(text))
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(loaded.animationSets), 1)
	if len(loaded.animationSets) == 1 do testing.expect(t, AnimationSetDef_Equal(loaded.animationSets[0], state.project.animationSets[0]), "round trip")
	testing.expect_value(t, loaded.scenes[0].nodes[hero].animationSet, "animations/hero.anim.xml")
	// Scripts get constants: the asset, and the Aseprite file's tags
	source := Scripts_AssetsSource(&state.project)
	testing.expect(t, strings.contains(source, `ANIMATION_HERO :: e.AnimationAsset{"animations/hero.anim.xml"}`), source)
	testing.expect(t, strings.contains(source, `ANIMATION_TAGS3 :: e.AnimationAsset{"assets/tags3.aseprite"}`), source)

	// The viewport draws it (the asset's sheet)
	state.viewport = {center = {0, 0}, zoom = 4, size = {64, 64}}
	pixels, ok := Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, ok, "rendered")
	if ok {
		drawn := 0
		for i := 0; i + 3 < len(pixels); i += 4 do if pixels[i] > 0 || pixels[i + 1] > 0 || pixels[i + 2] > 0 do drawn += 1
		testing.expectf(t, drawn > 0, "the sprite drew (%d px)", drawn)
	}

	// An Aseprite file's tags: read only in the panel (the undo steps above kept the selection:
	// they didn't touch the scene's nodes)
	testing.expect_value(t, state.selectedNode, hero)
	sendTo(&state, Node_Text_Changed{.Animation_Set, asePath})
	src = AnimEdit_Source(&state)
	testing.expectf(t, src.kind == .Aseprite && src.readOnly && src.animations != nil && len(src.animations^) == 3, "its tags: %v %v %s", src.kind, src.readOnly, state.project.scenes[0].nodes[hero].animationSet)
	sendTo(&state, Anim_Added{})
	testing.expect_value(t, len(AnimEdit_Source(&state).animations^), 3)
	pixels, ok = Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, ok, "drawn from its sheet")
	// Back to its own: one animation again
	sendTo(&state, Node_Text_Changed{.Animation_Set, ANIMATION_OWN})
	testing.expect_value(t, AnimEdit_Source(&state).kind, AnimSourceKind.Node)
	testing.expect_value(t, len(state.project.scenes[0].nodes[hero].animations), 1)

	// The browser's choice in the panel, and a new empty asset
	sendTo(&state, Anim_Set_New{})
	testing.expect_value(t, len(state.project.animationSets), 2)
	testing.expect_value(t, AnimEdit_Source(&state).path, "animations/animations.anim.xml")
	sendTo(&state, Anim_Asset_Shown(""))
	testing.expect_value(t, AnimEdit_Source(&state).kind, AnimSourceKind.Node)
	free_all(context.temp_allocator)
}

@(test)
animations_have_their_own_sheets_in_the_panel :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_animation_sheets"
	removeAll(dir)
	defer removeAll(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	// 320 x 100 (four balloons) and 128 x 64 (two lights)
	balloons, problem := Project_ImportAsset(&state.project, "tests/fixtures/ui_project/assets/balloons.png")
	testing.expect_value(t, problem, "")
	light, problem2 := Project_ImportAsset(&state.project, "tests/fixtures/ui_project/assets/light.png")
	testing.expect_value(t, problem2, "")
	if balloons < 0 || light < 0 do return
	balloonsPath, lightPath := state.project.assets[balloons].path, state.project.assets[light].path

	scene := &state.project.scenes[0]
	state.selectedNode = Scene_InsertNode(scene, "Hero", .AnimatedSprite, -1)
	animations :: proc(state: ^State) -> ^[dynamic]AnimationDef { return &state.project.scenes[0].nodes[state.selectedNode].animations }
	testing.expect_value(t, animations(&state)[0].sheet, "")

	// The first animation's sheet: 4 x 1 cells
	sendTo(&state, Anim_Sheet_Texture_Changed(balloonsPath))
	sendTo(&state, Anim_Field_Changed{.Columns, 4})
	testing.expect_value(t, animations(&state)[0].sheet, balloonsPath)
	testing.expect_value(t, AnimEdit_Cells(state.project.rootPath, animations(&state)[0]), 4)

	// A new one starts on the selected one's sheet and grid, then gets its own sheet
	sendTo(&state, Anim_Added{})
	testing.expect_value(t, state.animEditor.selected, 1)
	added := animations(&state)[1]
	testing.expect(t, added.sheet == balloonsPath && added.grid.columns == 4, "the selected animation's sheet")
	sendTo(&state, Anim_Sheet_Texture_Changed(lightPath))
	// Cut by cell size: from the 4 x 1 grid on 128 x 64, 32 x 64 cells; then 64 wide: two cells
	sendTo(&state, Anim_Grid_Mode_Changed("Size"))
	testing.expect_value(t, animations(&state)[1].grid.mode, e.SheetGridMode.Size)
	testing.expect_value(t, animations(&state)[1].grid.cellSize, [2]f32{32, 64})
	sendTo(&state, Anim_Field_Changed{.Cell_Width, 64})
	testing.expect_value(t, AnimEdit_Cells(state.project.rootPath, animations(&state)[1]), 2)
	// Its frames by count: no more than the sheet has
	sendTo(&state, Anim_Field_Changed{.Frames, 5})
	testing.expect_value(t, [2]int{animations(&state)[1].start, animations(&state)[1].end}, [2]int{0, 1})
	sendTo(&state, Anim_Field_Changed{.Frames, 1})
	testing.expect_value(t, animations(&state)[1].end, 0)
	// Back to columns x rows: the ones the cell size made
	sendTo(&state, Anim_Grid_Mode_Changed("Cells"))
	testing.expect(t, animations(&state)[1].grid.columns == 2 && animations(&state)[1].grid.rows == 1, "2 x 1")
	// The first keeps its own
	testing.expect(t, animations(&state)[0].sheet == balloonsPath && animations(&state)[0].grid.mode == .Cells, "the first's sheet")

	// An image dragged from the browser onto the panel: the selected animation's sheet
	state.assetDrag = {pressed = true, active = true, asset = balloons}
	sendTo(&state, Anim_Sheet_Dropped{})
	testing.expect_value(t, animations(&state)[1].sheet, balloonsPath)
	testing.expect(t, !state.assetDrag.pressed && !state.assetDrag.active, "the drag ended")

	// Saved and loaded: each animation's sheet and grid
	testing.expect_value(t, Project_Save(&state.project), "")
	text := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.count(text, `sheet="`) == 2 && !strings.contains(text, `texture=`), text)
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, NodeDef_Equal(loaded.scenes[0].nodes[state.selectedNode], state.project.scenes[0].nodes[state.selectedNode]), "round trip")

	// Every edit undoes: back to one animation without a sheet
	for _ in 0 ..< 20 do sendTo(&state, Action.Undo)
	testing.expect_value(t, len(animations(&state)), 1)
	testing.expect_value(t, animations(&state)[0].sheet, "")
	for _ in 0 ..< 3 do sendTo(&state, Action.Redo)
	testing.expect_value(t, len(animations(&state)), 2)
	testing.expect_value(t, animations(&state)[1].sheet, balloonsPath)
	free_all(context.temp_allocator)
}
