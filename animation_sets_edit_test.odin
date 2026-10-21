package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

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
	delete(node.texture)
	node.texture = strings.clone(asePath)
	node.columns, node.rows = 2, 2
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
	testing.expect(t, src.kind == .Set && len(src.animations^) == 1 && src.columns^ == 2, "the panel shows the asset")
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
	testing.expect(t, len(set.animations) == 2 && set.columns == 4, "edited")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.animationSets[0].columns, 2)
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
