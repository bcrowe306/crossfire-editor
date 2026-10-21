package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"

// A component has one root: nodes added, pasted, duplicated, dropped or moved to its top level
// go under the root; files with nodes beside it load with them under it (the engine's parser);
// node fields dropped on its script are paths from the root

@(private="file")
oneRootComponent :: proc() -> SceneDef {
	scene := SceneDef{name = strings.clone("hero"), component = strings.clone("components/hero.component.xml")}
	Scene_InsertNode(&scene, "Hero", .CharacterMover, -1)
	Scene_InsertNode(&scene, "Sprite", .Sprite, 0)
	return scene
}

@(test)
components_keep_one_root :: proc(t: ^testing.T) {
	scene := oneRootComponent()
	defer SceneDef_Destroy(&scene)

	// Added with nothing selected: under the root
	sound := Scene_InsertNode(&scene, "SwingSound", .AudioPlayer, -1)
	testing.expect_value(t, scene.nodes[sound].parent, 0)
	// Dropped in the viewport with nothing selected
	sprite := Scene_AddSpriteAt(&scene, "assets/a.png", -1, {10, 20})
	testing.expect_value(t, scene.nodes[sprite].parent, 0)
	testing.expect_value(t, scene.nodes[sprite].position, [2]f32{10, 20})
	// Pasted at the top level
	copied := Scene_CopySubtree(&scene, sound, context.temp_allocator)
	pasted := Scene_PasteSubtree(&scene, copied[:], -1)
	Subtree_Destroy(&copied)
	testing.expect_value(t, scene.nodes[pasted].parent, 0)
	// The root duplicated: the copy goes under it
	copyOfRoot := Scene_DuplicateNode(&scene, 0)
	testing.expect_value(t, scene.nodes[copyOfRoot].parent, 0)
	for n, i in scene.nodes do if i > 0 do testing.expectf(t, n.parent >= 0, "%s is beside the root", n.name)
	// Nothing moves beside the root; inside it is fine
	testing.expect(t, !Scene_CanMoveNode(&scene, sound, -1, .After), "to the end of the top level")
	testing.expect(t, !Scene_CanMoveNode(&scene, sound, 0, .Before), "before the root")
	testing.expect(t, !Scene_CanMoveNode(&scene, sound, 0, .After), "after the root")
	testing.expect(t, Scene_CanMoveNode(&scene, sound, 1, .After), "beside one of its children")

	// Fields dropped on a script no node has (an LDtk entity's, named like it): from the root
	testing.expect_value(t, NodeField_From(&scene, "Hero", -1), 0)
	testing.expect_value(t, Scene_NodePath(&scene, NodeField_From(&scene, "Hero", sound), sound, context.temp_allocator), "SwingSound")
	// In a scene: from the top level
	path := scene.component
	scene.component = ""
	testing.expect_value(t, NodeField_From(&scene, "Hero", -1), -1)
	scene.component = path
	free_all(context.temp_allocator)
}

@(test)
components_with_nodes_beside_the_root_load_with_them_under_it :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_component_roots"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory_all(joinPath(dir, "components", allocator = context.temp_allocator))
	file := `<?xml version="1.0" encoding="UTF-8"?>
<component formatVersion="13" name="hero">
	<node kind="CharacterMover" name="Hero" x="5" y="0">
		<node kind="Sprite" name="Sprite" x="0" y="-36"/>
	</node>
	<node kind="AudioPlayer" name="HitSound" x="0" y="0"/>
	<node kind="AudioPlayer" name="SwingSound" x="0" y="0"/>
</component>
`
	testing.expect(t, os.write_entire_file(joinPath(dir, "components/hero.component.xml", allocator = context.temp_allocator), transmute([]u8)file) == nil, "wrote it")
	scene, message := Project_LoadComponent(dir, "components/hero.component.xml")
	defer SceneDef_Destroy(&scene)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(scene.nodes), 4)
	for n, i in scene.nodes do if i > 0 do testing.expectf(t, n.parent >= 0, "%s is beside the root", n.name)
	// Their values as they were (now relative to the root)
	for n in scene.nodes do if n.name == "SwingSound" do testing.expect_value(t, n.position, [2]f32{0, 0})
	xml := SceneToXML(&scene, context.temp_allocator)
	testing.expect_value(t, strings.count(xml, "\n\t<node "), 1)
	free_all(context.temp_allocator)
}
